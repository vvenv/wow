#!/usr/bin/env bash
# 在线上服与本地服之间同步 characters 数据库。
#
#   bin/sync-characters.sh pull   # 线上 → 本地
#   bin/sync-characters.sh push   # 本地 → 线上
#   bin/sync-characters.sh dump   # 只导出远端到文件，不导入
#
# 环境变量 (都有默认值):
#   SERVER_HOST          线上服地址（默认取 server.conf 的 SERVER_HOST）
#   SERVER_SSH_USER      SSH 用户
#   SERVER_SSH_PASSWORD   SSH 密码 (用 sshpass)
#   LOCAL_DB_CONTAINER   本地数据库容器名
#   REMOTE_DB_CONTAINER  远端数据库容器名
#   DB_USER / DB_PASS    MariaDB 凭据
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP_DIR="$ROOT/downloads/db-sync"
mkdir -p "$DUMP_DIR"

# Finder 起的 .app 环境 PATH 很干净，docker 在 /usr/local/bin 里会找不到
export PATH="/usr/local/bin:/opt/homebrew/bin:${HOME}/.docker/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

find_cmd() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  for p in /usr/local/bin /opt/homebrew/bin "${HOME}/.docker/bin"; do
    if [ -x "$p/$name" ]; then
      echo "$p/$name"
      return 0
    fi
  done
  return 1
}

DOCKER="$(find_cmd docker)" || {
  echo "找不到 docker。请先安装并启动 Docker Desktop。" >&2
  exit 1
}
SSHPASS="$(find_cmd sshpass)" || {
  echo "找不到 sshpass。运行: brew install hudochenkov/sshpass/sshpass" >&2
  exit 1
}

[ -f "$ROOT/server.conf" ] && . "$ROOT/server.conf"
: "${SERVER_HOST:=${SERVER_HOST:-}}"
[ -n "$SERVER_HOST" ] || { echo "没有线上服地址：设 SERVER_HOST，或在 server.conf 里填 SERVER_HOST。" >&2; exit 1; }
: "${SERVER_SSH_USER:=${SERVER_SSH_USER:-root}}"
: "${SERVER_SSH_PASSWORD:=${SERVER_SSH_PASSWORD:-}}"
# 优先用 SSH 密钥。要用密码就设环境变量 SERVER_SSH_PASSWORD，
# 或写进不入库的 server.conf（SERVER_SSH_PASSWORD=...）。
: "${LOCAL_DB_CONTAINER:=}"
: "${REMOTE_DB_CONTAINER:=vmangos-database-1}"
: "${DB_USER:=mangos}"
: "${DB_PASS:=mangos}"

SSH="$SSHPASS -p $SERVER_SSH_PASSWORD ssh -o StrictHostKeyChecking=no ${SERVER_SSH_USER}@${SERVER_HOST}"

# 本地容器名可能带 compose 项目前缀，自动探测
resolve_local_db_container() {
  if [ -n "${LOCAL_DB_CONTAINER:-}" ]; then
    echo "$LOCAL_DB_CONTAINER"
    return 0
  fi
  "$DOCKER" ps --format '{{.Names}}' 2>/dev/null \
    | grep -E '(^|[-_])database[-_]1$|database$' \
    | head -1
}

require_local_db() {
  LOCAL_DB_CONTAINER="$(resolve_local_db_container || true)"
  if [ -z "${LOCAL_DB_CONTAINER:-}" ]; then
    echo "本地数据库容器没在跑。先在 vmangos-deploy 里执行: docker compose up -d database" >&2
    exit 1
  fi
}

ts() { date +%Y%m%d-%H%M%S; }

log() { echo "$*" >&2; }

dump_remote() {
  local f="$DUMP_DIR/characters-remote-$(ts).sql"
  log "⬇  导出线上 characters → $f"
  $SSH "docker exec $REMOTE_DB_CONTAINER mariadb-dump -u$DB_USER -p$DB_PASS --single-transaction characters" > "$f"
  local size; size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -lt 1000 ]; then
    log "⚠  导出文件太小（${size} bytes），可能失败了"
    cat "$f" >&2
    return 1
  fi
  log "   $(wc -l < "$f" | tr -d ' ') 行, $(( size / 1024 )) KB"
  printf '%s\n' "$f"
}

dump_local() {
  local f="$DUMP_DIR/characters-local-$(ts).sql"
  log "⬇  导出本地 characters → $f"
  "$DOCKER" exec "$LOCAL_DB_CONTAINER" mariadb-dump -u"$DB_USER" -p"$DB_PASS" --single-transaction characters > "$f"
  local size; size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -lt 1000 ]; then
    log "⚠  导出文件太小（${size} bytes），可能失败了"
    cat "$f" >&2
    return 1
  fi
  log "   $(wc -l < "$f" | tr -d ' ') 行, $(( size / 1024 )) KB"
  printf '%s\n' "$f"
}

import_local() {
  local f="$1"
  [ -f "$f" ] || { log "找不到导入文件: $f"; return 1; }
  log "⬆  导入 $f → 本地 characters（整库覆盖）"
  "$DOCKER" exec -i "$LOCAL_DB_CONTAINER" mariadb -u"$DB_USER" -p"$DB_PASS" characters < "$f"
  log "   完成"
}

import_remote() {
  local f="$1"
  [ -f "$f" ] || { log "找不到导入文件: $f"; return 1; }
  log "⬆  导入 $f → 线上 characters（整库覆盖）"
  $SSH "docker exec -i $REMOTE_DB_CONTAINER mariadb -u$DB_USER -p$DB_PASS characters" < "$f"
  log "   完成"
}

count_chars() {
  local where="$1"  # "local" or "remote"
  if [ "$where" = "local" ]; then
    "$DOCKER" exec "$LOCAL_DB_CONTAINER" mariadb -u"$DB_USER" -p"$DB_PASS" characters \
      -N -e "SELECT COUNT(*) FROM characters;" 2>/dev/null || echo "?"
  else
    $SSH "docker exec $REMOTE_DB_CONTAINER mariadb -u$DB_USER -p$DB_PASS characters \
      -N -e 'SELECT COUNT(*) FROM characters;'" 2>/dev/null || echo "?"
  fi
}

case "${1:-help}" in
  pull|push)
    CMD="$1"
    FORCE=0
    [[ "${2:-}" == "--force" || "${2:-}" == "-f" ]] && FORCE=1
    require_local_db
    if [ "$CMD" = "pull" ]; then
      log "=== 线上 → 本地 ==="
      log "线上角色数: $(count_chars remote)"
      log "本地角色数: $(count_chars local)"
      log ""
      if [ "$FORCE" -eq 0 ]; then
        log "--- 备份本地 ---"
        dump_local || true
        log ""
      else
        log "--- 直接覆盖（跳过本地备份）---"
      fi
      log "--- 导出线上 ---"
      remote_file="$(dump_remote)"
      log ""
      import_local "$remote_file"
      log ""
      log "同步后本地角色数: $(count_chars local)"
      log "=== 完成 ==="
    else
      log "=== 本地 → 线上 ==="
      log "本地角色数: $(count_chars local)"
      log "线上角色数: $(count_chars remote)"
      log ""
      if [ "$FORCE" -eq 0 ]; then
        log "--- 备份线上 ---"
        dump_remote || true
        log ""
      else
        log "--- 直接覆盖（跳过线上备份）---"
      fi
      log "--- 导出本地 ---"
      local_file="$(dump_local)"
      log ""
      import_remote "$local_file"
      log ""
      log "同步后线上角色数: $(count_chars remote)"
      log "=== 完成 ==="
    fi
    ;;
  dump)
    dump_remote
    ;;
  status)
    LOCAL_DB_CONTAINER="$(resolve_local_db_container || true)"
    echo "本地角色数: $(count_chars local)"
    echo "线上角色数: $(count_chars remote)"
    ;;
  *)
    echo "用法: $0 {pull|push|dump|status} [--force]"
    echo ""
    echo "  pull [--force]   线上 → 本地（默认先备份本地）"
    echo "  push [--force]   本地 → 线上（默认先备份线上）"
    echo "  --force          跳过备份，直接整库覆盖"
    echo "  dump    只导出线上到文件"
    echo "  status  显示两边角色数量"
    exit 1
    ;;
esac
