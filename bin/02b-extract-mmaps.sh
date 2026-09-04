#!/bin/bash
# 提取 mmaps（寻路网格）。耗时数小时，不影响登录和进游戏。
# 完成后需要 docker compose restart mangosd 让服务器加载。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/vmangos-deploy"
docker run -i --rm --name vmangos-extract-mmaps \
  -v ./storage/mangosd/client-data:/opt/vmangos/storage/client-data \
  -v ./storage/mangosd/extracted-data:/opt/vmangos/storage/extracted-data \
  --entrypoint sh \
  ghcr.io/mserajnik/vmangos-server:5875 -c '
set -eu
eval "$(fixuid -q)"
CD=/opt/vmangos/storage/client-data
ED=/opt/vmangos/storage/extracted-data
EX=/opt/vmangos/bin/Extractors
cd "$CD"
# MoveMapGenerator 需要 maps/vmaps 与 Buildings 同在客户端目录下
ln -sfn "$ED/maps"  ./maps
ln -sfn "$ED/vmaps" ./vmaps
rm -rf ./mmaps
echo "=== MoveMapGenerator 开始 $(date) ==="
"$EX/mmap_extract.py" --configInputPath "$EX/config.json" --offMeshInput "$EX/offmesh.txt"
echo "=== 放置 mmaps ==="
rm -rf "$ED/mmaps"
mv ./mmaps "$ED/"
rm -f ./maps ./vmaps
rm -rf ./Buildings
echo "=== 完成 $(date) ==="
du -sh "$ED/mmaps"
'
