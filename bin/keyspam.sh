#!/bin/bash
# 向游戏窗口连续发送真实按键（macOS 硬件事件），用于驱动 AutoGrind 的
# 「Do One Step」绑定 —— vanilla 客户端要求施法必须由硬件输入触发，
# 插件内部循环调用会被静默丢弃，只有真实按键才生效。
#
# 安全设计：只在游戏处于前台时才发键，切走窗口立即暂停，避免误输入到别处。
#
# 用法:
#   keyspam.sh                      默认：反引号键 `，每 0.35 秒一次
#   keyspam.sh --key 6 --interval 0.5
#   keyspam.sh --list-keys
#   Ctrl+C 停止
set -u

KEY_NAME="grave"
INTERVAL=0.35
APP_PATTERN="wine|wow|WoWSilicon"

# macOS 虚拟键码
keycode_of() {
  case "$1" in
    grave|\`) echo 50 ;;  1) echo 18 ;;  2) echo 19 ;;  3) echo 20 ;;  4) echo 21 ;;
    5) echo 23 ;;  6) echo 22 ;;  7) echo 26 ;;  8) echo 28 ;;  9) echo 25 ;;  0) echo 29 ;;
    minus|-) echo 27 ;;  equal|=) echo 24 ;;
    q) echo 12 ;; e) echo 14 ;; r) echo 15 ;; t) echo 17 ;; f) echo 3 ;; g) echo 5 ;;
    z) echo 6 ;; x) echo 7 ;; c) echo 8 ;; v) echo 9 ;; b) echo 11 ;;
    *) echo "" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY_NAME="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --app) APP_PATTERN="$2"; shift 2 ;;
    --list-keys) echo "支持: \` 1-9 0 - = q e r t f g z x c v b"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

CODE=$(keycode_of "$KEY_NAME")
[ -n "$CODE" ] || { echo "不支持的按键: ${KEY_NAME}（用 --list-keys 查看）" >&2; exit 2; }

frontmost() {
  osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null
}

# 权限自检
probe=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>&1)
if echo "$probe" | grep -qi "not allowed\|1002\|assistive"; then
  echo "❌ 缺少辅助功能权限。"
  echo "   打开：系统设置 → 隐私与安全性 → 辅助功能"
  echo "   把你的终端（Terminal / iTerm）勾选启用，然后重开终端再运行。"
  exit 1
fi

echo "按键连发已就绪"
echo "  按键     : $KEY_NAME (keycode $CODE)"
echo "  间隔     : ${INTERVAL}s"
echo "  仅在前台应用匹配 /$APP_PATTERN/ 时发送"
echo "  Ctrl+C 停止"
echo
echo "请在 5 秒内切换到游戏窗口..."
sleep 5

sent=0; paused=0
trap 'echo; echo "已停止。共发送 $sent 次按键。"; exit 0' INT TERM

while true; do
  app=$(frontmost)
  if echo "$app" | grep -qiE "$APP_PATTERN"; then
    if [ "$paused" = "1" ]; then echo "▶︎ 游戏回到前台，继续 ($app)"; paused=0; fi
    osascript -e "tell application \"System Events\" to key code $CODE" 2>/dev/null
    sent=$((sent+1))
    if [ $((sent % 50)) -eq 0 ]; then echo "  已发送 $sent 次"; fi
  else
    if [ "$paused" = "0" ]; then echo "⏸ 前台是「${app}」，暂停发送（切回游戏自动继续）"; paused=1; fi
  fi
  sleep "$INTERVAL"
done
