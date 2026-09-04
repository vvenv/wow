#!/usr/bin/env bash
# 切换两个客户端连的服务器地址。
#
#   bin/set-realmlist.sh                 # 看当前指向
#   bin/set-realmlist.sh online          # 指向 server.conf 里的 SERVER_HOST
#   bin/set-realmlist.sh local           # 指回本地 127.0.0.1
#   bin/set-realmlist.sh 1.2.3.4         # 指向任意地址
#
# 改两个地方：realmlist.wtf（启动时读）和 WTF/Config.wtf 的 SET realmList
# （客户端退出时会回写这里，只改一个会被覆盖回去）。客户端必须先退出。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENTS=(client client-zhCN)

# 线上地址放在不入库的 server.conf 里，见 server.conf.example
[ -f "$ROOT/server.conf" ] && . "$ROOT/server.conf"
SERVER_ADDR="${SERVER_HOST:-}"
LOCAL_ADDR=127.0.0.1

show() {
  for c in "${CLIENTS[@]}"; do
    d="$ROOT/$c"
    [ -d "$d" ] || continue
    printf '%-12s realmlist.wtf=%-16s Config.wtf=%s\n' "$c" \
      "$(awk '/realmlist/{print $3}' "$d/realmlist.wtf" 2>/dev/null || echo '-')" \
      "$(awk -F'"' '/^SET realmList/{print $2}' "$d/WTF/Config.wtf" 2>/dev/null || echo '-')"
  done
}

[ $# -eq 0 ] && { show; exit 0; }

case "$1" in
  online)
    [ -n "$SERVER_ADDR" ] || { echo "server.conf 里没有 SERVER_HOST —— 先照 server.conf.example 填一个。" >&2; exit 1; }
    ADDR=$SERVER_ADDR ;;
  local)  ADDR=$LOCAL_ADDR ;;
  *)      ADDR=$1 ;;
esac

if pgrep -qf 'WoW\.exe|WoW_tweaked\.exe'; then
  echo "客户端还开着，先退出再改（退出时会把 Config.wtf 写回去）。" >&2
  exit 1
fi

for c in "${CLIENTS[@]}"; do
  d="$ROOT/$c"
  [ -d "$d" ] || continue

  printf 'set realmlist %s\n' "$ADDR" > "$d/realmlist.wtf"

  cfg="$d/WTF/Config.wtf"
  if [ -f "$cfg" ]; then
    # 单独写临时文件再整体替换，避免半写状态
    tmp="$cfg.tmp.$$"
    if grep -q '^SET realmList ' "$cfg"; then
      sed "s|^SET realmList .*|SET realmList \"$ADDR\"|" "$cfg" > "$tmp"
    else
      { cat "$cfg"; printf 'SET realmList "%s"\n' "$ADDR"; } > "$tmp"
    fi
    mv "$tmp" "$cfg"
  fi
done

echo "已切到 ${ADDR}："
show
