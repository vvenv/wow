#!/bin/bash
# 只提取 maps / vmaps / dbc（跳过耗时数小时的 mmaps）
# 保留 Buildings/ 供后续 mmaps 步骤使用
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/vmangos-deploy"
docker run -i --rm --name vmangos-extract-maps \
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
rm -rf ./Cameras ./dbc ./maps ./vmaps
echo "=== [1/3] MapExtractor ==="
"$EX/MapExtractor"
echo "=== [2/3] VMapExtractor ==="
"$EX/VMapExtractor"
echo "=== [3/3] VMapAssembler ==="
"$EX/VMapAssembler"
rm -rf ./Cameras
echo "=== 放置到 extracted-data ==="
rm -rf "$ED/$VMANGOS_CLIENT_VERSION" "$ED/maps" "$ED/vmaps"
mkdir -p "$ED/$VMANGOS_CLIENT_VERSION"
mv ./dbc "$ED/$VMANGOS_CLIENT_VERSION/"
mv ./maps ./vmaps "$ED/"
echo "=== 完成。Buildings/ 已保留供 mmaps 使用 ==="
du -sh "$ED"/* 2>/dev/null || true
'
