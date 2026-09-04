#!/bin/bash
# 多线程下载客户端包。慢网络下 aria2c -x16 相比 curl 是数量级差距
# （实测 0.5 MB/s -> 4~5 MB/s，3 小时 -> 25 分钟）。
#
# 用法: fetch-client.sh <url> [输出目录] [文件名]
set -euo pipefail
URL="$1"; DIR="${2:-.}"; NAME="${3:-$(basename "${URL%%\?*}")}"
command -v aria2c >/dev/null || { echo "请先安装 aria2: brew install aria2" >&2; exit 1; }
mkdir -p "$DIR"
aria2c -c -x16 -s16 -k1M --file-allocation=none \
       --max-tries=0 --retry-wait=5 --summary-interval=60 \
       -U "Mozilla/5.0" -d "$DIR" -o "$NAME" "$URL"
echo "完成: $DIR/$NAME ($(stat -f%z "$DIR/$NAME" 2>/dev/null || stat -c%s "$DIR/$NAME") bytes)"
echo "提示: 若包内带 SHA256SUMS，务必校验：cd <解压目录> && shasum -a 256 -c SHA256SUMS"
