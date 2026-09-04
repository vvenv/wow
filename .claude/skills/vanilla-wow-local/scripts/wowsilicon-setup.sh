#!/bin/bash
# 配置 WoWSilicon 接入本地服务器：realmlist + 补丁 + 就绪检查。
#
# 用法: wowsilicon-setup.sh <游戏目录> [realmlist地址]
#   例: wowsilicon-setup.sh ~/vvenv/wow/client 127.0.0.1
set -euo pipefail
GAME="${1:?用法: wowsilicon-setup.sh <游戏目录> [realmlist地址]}"
REALM="${2:-127.0.0.1}"
APP=/Applications/WoWSilicon.app/Contents/Resources
PATCHING="$APP/WoWSilicon-swift_WoWSiliconSwift.bundle/Patching"

[ -f "$GAME/WoW.exe" ] || { echo "错误: $GAME 下没有 WoW.exe" >&2; exit 1; }
[ -d "$PATCHING" ]     || { echo "错误: 未找到 WoWSilicon.app，请先安装" >&2; exit 1; }

echo "==> realmlist -> $REALM"
# 两处都要改：Config.wtf 里缓存的 SET realmList 优先级高于 realmlist.wtf
echo "set realmlist $REALM" > "$GAME/realmlist.wtf"
if [ -f "$GAME/WTF/Config.wtf" ]; then
  cp -n "$GAME/WTF/Config.wtf" "$GAME/WTF/Config.wtf.bak" 2>/dev/null || true
  if grep -q 'SET realmList' "$GAME/WTF/Config.wtf"; then
    sed -i '' "s|SET realmList \".*\"|SET realmList \"$REALM\"|" "$GAME/WTF/Config.wtf"
  else
    printf 'SET realmList "%s"\n' "$REALM" >> "$GAME/WTF/Config.wtf"
  fi
  grep -i realmlist "$GAME/WTF/Config.wtf" || true
fi

echo "==> 补齐 WoWSilicon 补丁（UI 静默失败时的兜底）"
mkdir -p "$GAME/mods"
cp -n "$PATCHING/winerosetta/winerosetta.dll" "$GAME/mods/" 2>/dev/null || true
cp -n "$PATCHING/winerosetta/libDllLdr.dll"   "$GAME/mods/" 2>/dev/null || true
[ -f "$GAME/d3d9.dll" ] || cp "$PATCHING/d9vk/d3d9.dll" "$GAME/d3d9.dll"
cp -n "$GAME/dlls.txt" "$GAME/dlls.txt.bak" 2>/dev/null || true
touch "$GAME/dlls.txt"
grep -q "mods/winerosetta.dll" "$GAME/dlls.txt" || printf 'mods/winerosetta.dll\n' >> "$GAME/dlls.txt"

echo "==> 就绪检查"
ok=0
for f in "$GAME/mods/winerosetta.dll" "$GAME/mods/libDllLdr.dll" "$GAME/d3d9.dll"; do
  if [ -f "$f" ]; then echo "  ✓ $(basename "$f")"; else echo "  ✗ 缺失 $f"; ok=1; fi
done
if grep -q "mods/winerosetta.dll" "$GAME/dlls.txt"; then echo "  ✓ dlls.txt 已登记"; else echo "  ✗ dlls.txt 未登记"; ok=1; fi

echo
echo "==> 预填 WoWSilicon 的 game_path（请先退出 WoWSilicon，否则会被覆盖）"
echo "GAME_PATH=$GAME python3 - <<'PY'"
cat <<'PY'
import json, os
p = os.path.expanduser("~/Library/Application Support/WoWSilicon/versions.json")
d = json.load(open(p))
d["currentVersionID"] = "vanillasilicon"
d["versions"]["vanillasilicon"]["game_path"] = os.environ["GAME_PATH"]
json.dump(d, open(p, "w"), indent=2)
print("game_path =", os.environ["GAME_PATH"])
PY
echo "PY"
exit $ok
