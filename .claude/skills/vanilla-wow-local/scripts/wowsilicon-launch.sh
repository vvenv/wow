#!/bin/bash
# 绕开 WoWSilicon UI 直接启动游戏。UI 的 Play 按钮静默失败时用这个。
# 环境变量取自实际运行进程的命令行。
#
# 用法: wowsilicon-launch.sh <游戏目录>
set -euo pipefail
GAME="${1:?用法: wowsilicon-launch.sh <游戏目录>}"
APP=/Applications/WoWSilicon.app/Contents/Resources
cd "$GAME"
exec env \
  ROSETTA_X87_PATH="$APP/WoWSilicon-swift_WoWSiliconSwift.bundle/Patching/rosettax87/rosettax87" \
  DYLD_LIBRARY_PATH="$APP/Wine/lib/external" \
  WINE_LARGE_ADDRESS_AWARE=1 \
  WINEDLLOVERRIDES="d3d9=n" \
  MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 \
  DXVK_ASYNC=1 \
  "$APP/Wine/bin/wine" "$GAME/WoW.exe"
