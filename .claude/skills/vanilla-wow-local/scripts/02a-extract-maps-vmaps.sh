#!/bin/bash
# 提取 maps / vmaps / dbc —— 跳过耗时数小时的 mmaps，几分钟即可让服务器可登录。
# 刻意保留 Buildings/，供后续 02b-extract-mmaps.sh 使用。
#
# 用法: 02a-extract-maps-vmaps.sh [vmangos-deploy 目录] [镜像 tag]
set -euo pipefail
DEPLOY="${1:-$PWD}"
TAG="${2:-5875}"
IMAGE="ghcr.io/mserajnik/vmangos-server:${TAG}"

[ -d "$DEPLOY/storage/mangosd/client-data/Data" ] || {
  echo "错误: 找不到 $DEPLOY/storage/mangosd/client-data/Data" >&2
  echo "请先把客户端目录（含 Data/*.MPQ）放到 storage/mangosd/client-data/" >&2
  exit 1; }

cd "$DEPLOY"
docker run -i --rm --name vmangos-extract-maps \
  -v ./storage/mangosd/client-data:/opt/vmangos/storage/client-data \
  -v ./storage/mangosd/extracted-data:/opt/vmangos/storage/extracted-data \
  --entrypoint sh "$IMAGE" -c '
set -eu
eval "$(fixuid -q)"
CD=/opt/vmangos/storage/client-data
ED=/opt/vmangos/storage/extracted-data
EX=/opt/vmangos/bin/Extractors
cd "$CD"
rm -rf ./Cameras ./dbc ./maps ./vmaps
echo "=== [1/3] MapExtractor ==="   ; "$EX/MapExtractor"
echo "=== [2/3] VMapExtractor ==="  ; "$EX/VMapExtractor"
echo "=== [3/3] VMapAssembler ===" ; "$EX/VMapAssembler"
rm -rf ./Cameras
rm -rf "$ED/$VMANGOS_CLIENT_VERSION" "$ED/maps" "$ED/vmaps"
mkdir -p "$ED/$VMANGOS_CLIENT_VERSION"
mv ./dbc "$ED/$VMANGOS_CLIENT_VERSION/"
mv ./maps ./vmaps "$ED/"
echo "=== 完成。Buildings/ 已保留供 mmaps 使用 ==="
du -sh "$ED"/* 2>/dev/null || true
'
