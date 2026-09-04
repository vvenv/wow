#!/usr/bin/env bash
# Launch a Windows 1.12.1 client folder through WoWSilicon's Wine + rosettax87,
# the same way the WoWSilicon app does it (command line copied from a live run).
#
#   bin/play-wine.sh                 # client/        (enUS)
#   bin/play-wine.sh client-zhCN     # another folder (Chinese)
#   EXE=WoW.exe bin/play-wine.sh ... # pick the binary explicitly
#
# Note: this does NOT go through VanillaFixes -- neither does the app itself on
# macOS; rosettax87 already handles the x87/RDTSC side. DXVK comes from the
# d3d9.dll inside the client folder (WINEDLLOVERRIDES d3d9=n), never from the
# Wine prefix -- installing it into the prefix breaks every client in it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-client}"
case "$DIR" in /*) ;; *) DIR="$ROOT/$DIR" ;; esac
[ -d "$DIR" ] || { echo "no such client folder: $DIR" >&2; exit 1; }

WS="/Applications/WoWSilicon.app/Contents/Resources"
[ -x "$WS/Wine/bin/wine" ] || { echo "WoWSilicon not found at /Applications" >&2; exit 1; }

if [ -n "${EXE:-}" ]; then :
elif [ -f "$DIR/WoW_tweaked.exe" ]; then EXE=WoW_tweaked.exe
elif [ -f "$DIR/WoW.exe" ]; then EXE=WoW.exe
else echo "no WoW.exe / WoW_tweaked.exe in $DIR" >&2; exit 1; fi

# Re-apply after vanilla-tweaks regenerates the exe. No-op if already patched.
if [ "$EXE" = "WoW_tweaked.exe" ]; then
  python3 "$ROOT/bin/patch-itemc-nullguard.py" "$DIR/$EXE" >/dev/null
fi

# Force windowed mode. Exclusive fullscreen is the one setting that reliably
# breaks this client under Wine (the mode switch hangs on restore). The window
# opens at gxResolution rather than filling the screen -- set MAXIMIZE=1 for the
# borderless maximised window instead, or WINDOWED=0 to leave both cvars alone.
ensure_cvar() {
  local f="$1" k="$2" v="$3"
  [ -f "$f" ] || return 0
  if grep -q "^SET $k " "$f"; then
    sed -i '' "s|^SET $k .*|SET $k \"$v\"|" "$f"
  else
    printf 'SET %s "%s"\n' "$k" "$v" >> "$f"
  fi
}
if [ "${WINDOWED:-1}" = "1" ]; then
  ensure_cvar "$DIR/WTF/Config.wtf" gxWindow 1
  ensure_cvar "$DIR/WTF/Config.wtf" gxMaximize "${MAXIMIZE:-0}"
fi

# Match the Unix locale to the client's language. Wine derives the ANSI
# codepage AND the keyboard layout from LC_ALL/LANG at startup -- it regenerates
# the Nls\CodePage and Keyboard Layout\Preload registry values from it, so
# editing those by hand does nothing. imm32 converts IME composition with the
# *keyboard layout's* codepage, so with an en_US locale (0409 -> CP1252) every
# Chinese character the input method produces arrives as '?'. Override with
# WINE_LOCALE=... if you need something else.
client_locale="$(sed -n 's/^SET locale "\(.*\)"$/\1/p' "$DIR/WTF/Config.wtf" 2>/dev/null | head -1)"
if [ -n "${WINE_LOCALE:-}" ]; then
  export LC_ALL="$WINE_LOCALE" LANG="$WINE_LOCALE"
else
  case "$client_locale" in
    zhCN) export LC_ALL=zh_CN.UTF-8 LANG=zh_CN.UTF-8 ;;
    zhTW) export LC_ALL=zh_TW.UTF-8 LANG=zh_TW.UTF-8 ;;
    koKR) export LC_ALL=ko_KR.UTF-8 LANG=ko_KR.UTF-8 ;;
  esac
fi

echo "launching $EXE from $DIR (client locale ${client_locale:-?}, LC_ALL=${LC_ALL:-<inherited>})"
cd "$DIR"
export ROSETTA_X87_PATH="$WS/WoWSilicon-swift_WoWSiliconSwift.bundle/Patching/rosettax87/rosettax87"
export DYLD_LIBRARY_PATH="$WS/Wine/lib/external"
export WINE_LARGE_ADDRESS_AWARE=1
export WINEDLLOVERRIDES="d3d9=n"
export MTL_HUD_ENABLED=0
export MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1
export DXVK_ASYNC=1
exec "$WS/Wine/bin/wine" "$DIR/$EXE"
