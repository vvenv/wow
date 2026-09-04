#!/bin/bash
# 等 mmaps 提取结束；成功才重启 mangosd 加载寻路网格。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/downloads/extract-mmaps.log"
ED="$ROOT/vmangos-deploy/storage/mangosd/extracted-data"

while docker ps --filter name=vmangos-extract-mmaps -q | grep -q .; do sleep 60; done

N=$(ls "$ED/mmaps" 2>/dev/null | wc -l | tr -d ' ')
if [ "${N:-0}" -lt 100 ]; then
  echo "❌ mmaps 提取未成功完成（$ED/mmaps 只有 ${N:-0} 个文件），不重启 mangosd。"
  grep -aE "error|Error|Traceback|Killed|No space" "$LOG" | tail -10
  exit 1
fi

echo "✅ mmaps 提取完成：$N 个 mmtile，$(du -sh "$ED/mmaps" | cut -f1)"
grep -aE "Finished processing|transport gameobject" "$LOG" | tail -3

echo "==> 重启 mangosd（在线玩家会被断开，角色数据会正常存盘）"
cd "$ROOT/vmangos-deploy"
docker compose restart mangosd 2>&1 | tail -3

until [ "$(docker inspect -f '{{.State.Health.Status}}' vmangos-deploy-mangosd-1 2>/dev/null)" = "healthy" ]; do sleep 10; done
echo "==> mangosd 已就绪"
docker compose logs mangosd --since 3m 2>&1 | grep -aiE "mmap|movemap|World initialized|ERROR" | tail -12
