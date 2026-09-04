#!/bin/bash
# 解压 1.12.1 客户端到 vmangos-deploy 的 client-data 目录（服务端和客户端共用同一份 MPQ）
#
# 一次性引导步骤，已经跑完。2026-09-03 删掉了 downloads/ 里的两个客户端 zip
# （合计 10.3G），所以这个脚本现在跑不了。要重跑得先重新下载 $ZIP。
#
# 注意：重装客户端才需要它。重新提取 maps/vmaps/mmaps 不需要——那些只读
# client/Data 里的 MPQ，13 个 MPQ 都还在原地（见 bin/02*-extract-*.sh）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$ROOT/downloads/Stonetavern-Classic-1.12.1.zip"
DEST="$ROOT/vmangos-deploy/storage/mangosd/client-data"

echo "==> 解压 $ZIP -> $DEST"
mkdir -p "$DEST"
# 只解压 Data/ 与 WoW.exe（游戏本体和 VMaNGOS 提取器都只需要这些），去掉顶层目录
ditto -x -k "$ZIP" "$ROOT/downloads/_unzip"
mv "$ROOT/downloads/_unzip/Stonetavern-Classic-1.12.1/"* "$DEST/"
rm -rf "$ROOT/downloads/_unzip"

echo "==> 校验 MPQ"
ls -la "$DEST/Data"/*.MPQ
