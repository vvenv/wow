#!/bin/bash
# 提取 mmaps（NPC 寻路网格）。耗时数小时，但不影响登录和进游戏。
# 完成后需 docker compose restart mangosd（或用 04-mmaps-then-restart.sh 自动处理）。
#
# 用法: 02b-extract-mmaps.sh [vmangos-deploy 目录] [镜像 tag]
set -euo pipefail
DEPLOY="${1:-$PWD}"
TAG="${2:-5875}"
IMAGE="ghcr.io/mserajnik/vmangos-server:${TAG}"

[ -d "$DEPLOY/storage/mangosd/client-data/Buildings" ] || {
  echo "错误: 找不到 Buildings/，请先运行 02a-extract-maps-vmaps.sh" >&2; exit 1; }

cd "$DEPLOY"
docker run -i --rm --name vmangos-extract-mmaps \
  -v ./storage/mangosd/client-data:/opt/vmangos/storage/client-data \
  -v ./storage/mangosd/extracted-data:/opt/vmangos/storage/extracted-data \
  --entrypoint sh "$IMAGE" -c '
set -eu
eval "$(fixuid -q)"
CD=/opt/vmangos/storage/client-data
ED=/opt/vmangos/storage/extracted-data
EX=/opt/vmangos/bin/Extractors
cd "$CD"
# MoveMapGenerator 要求 maps/vmaps 与 Buildings 同在客户端目录下
ln -sfn "$ED/maps" ./maps
ln -sfn "$ED/vmaps" ./vmaps
rm -rf ./mmaps
echo "=== MoveMapGenerator 开始 $(date) ==="
"$EX/mmap_extract.py" --configInputPath "$EX/config.json" --offMeshInput "$EX/offmesh.txt"
rm -rf "$ED/mmaps"; mv ./mmaps "$ED/"
rm -f ./maps ./vmaps; rm -rf ./Buildings
echo "=== 完成 $(date) ==="; du -sh "$ED/mmaps"
'
