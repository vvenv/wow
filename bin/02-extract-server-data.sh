#!/bin/bash
# VMaNGOS 服务端数据提取：maps / vmaps / mmaps / dbc
# 注意：mmaps 提取很慢，可能数小时。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/vmangos-deploy"
docker run -i \
  -v ./storage/mangosd/client-data:/opt/vmangos/storage/client-data \
  -v ./storage/mangosd/extracted-data:/opt/vmangos/storage/extracted-data \
  --rm \
  ghcr.io/mserajnik/vmangos-server:5875 \
  extract-client-data --force
