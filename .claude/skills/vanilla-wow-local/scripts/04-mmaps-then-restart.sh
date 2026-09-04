#!/bin/bash
# 等 mmaps 提取结束；**校验产物后**才重启 mangosd。
# 用法: 04-mmaps-then-restart.sh [vmangos-deploy 目录]
set -u
DEPLOY="${1:-$PWD}"
ED="$DEPLOY/storage/mangosd/extracted-data"

while docker ps --filter name=vmangos-extract-mmaps -q | grep -q .; do sleep 60; done

N=$(ls "$ED/mmaps" 2>/dev/null | wc -l | tr -d ' ')
if [ "${N:-0}" -lt 100 ]; then
  echo "❌ mmaps 提取未成功（$ED/mmaps 仅 ${N:-0} 个文件），不重启 mangosd。"
  exit 1
fi
echo "✅ mmaps 完成：$N 个 mmtile，$(du -sh "$ED/mmaps" | cut -f1)"
echo "==> 重启 mangosd（在线玩家会断线，角色数据正常存盘）"
cd "$DEPLOY" && docker compose restart mangosd
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q mangosd)" 2>/dev/null)" = "healthy" ]; do sleep 10; done
echo "==> mangosd 已就绪"
