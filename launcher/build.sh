#!/usr/bin/env bash
# 把 launcher/*.swift 编译成仓库根目录的 WoW.app。
#
#   launcher/build.sh
#
# 改完 Swift 必须重跑这个，.app 里装的是编译好的二进制。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/launcher"
APP="$ROOT/WoW.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

command -v swiftc >/dev/null || { echo "没有 swiftc，装 Xcode 命令行工具" >&2; exit 1; }

mkdir -p "$MACOS" "$RES"

# 图标：make-icon.swift 或 emblem.png 比 wow.icns 新就重新生成一整套尺寸
if [ ! -f "$SRC/wow.icns" ] \
   || [ "$SRC/make-icon.swift" -nt "$SRC/wow.icns" ] \
   || [ "$SRC/emblem.png" -nt "$SRC/wow.icns" ]; then
  echo "重新生成图标…"
  mkicon="$(mktemp -d)/mkicon"
  swiftc -O -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI \
    -o "$mkicon" "$SRC/make-icon.swift"
  "$mkicon" "$SRC" "$SRC/wow.icns"
fi
cp "$SRC/wow.icns" "$RES/wow.icns"
# 面板底栏那枚徽章用的就是图标的源图
cp "$SRC/emblem.png" "$RES/emblem.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>魔兽世界</string>
  <key>CFBundleDisplayName</key><string>魔兽世界</string>
  <key>CFBundleIdentifier</key><string>dev.vvenv.wow.launcher</string>
  <key>CFBundleExecutable</key><string>WoWLauncher</string>
  <key>CFBundleIconFile</key><string>wow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.12.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 除 make-icon.swift 外的全部源文件 —— 它有自己的顶层代码，跟 main.swift 冲突。
# 用通配而不是列文件名：加一个 .swift 就忘了改这里，是很容易踩的坑。
SOURCES=()
for f in "$SRC"/*.swift; do
  [ "$(basename "$f")" = "make-icon.swift" ] && continue
  SOURCES+=("$f")
done

# -parse-as-library 不能用：main.swift 里是顶层代码（要在开窗前判断 ⌥ 键）
swiftc -O \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI \
  -o "$MACOS/WoWLauncher" \
  "${SOURCES[@]}"

# 签名。优先用本机那张自签证书 —— ad-hoc 签名的指定要求是一串 cdhash，
# 二进制一变就变，辅助功能授权（原生全屏要用）每次编译都会作废。
# 用证书签的话指定要求只跟证书绑定，重新编译不掉。见 make-signing-identity.sh。
SIGN_SHA1=$(security find-certificate -c "WoW Launcher Local Signing" -Z 2>/dev/null \
            | awk '/SHA-1 hash:/{print $3}')
if [ -n "${SIGN_SHA1:-}" ]; then
  codesign --force --deep --sign "$SIGN_SHA1" "$APP" >/dev/null 2>&1 || \
    echo "codesign 失败，双击若被拦：右键 → 打开" >&2
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "codesign 失败，双击若被拦：右键 → 打开" >&2
  echo "提示：用的是 ad-hoc 签名，辅助功能授权每次编译都会掉。" >&2
  echo "      跑一次 launcher/make-signing-identity.sh 就能根治。" >&2
fi

touch "$APP"          # 让 Finder 重读 Info.plist / 图标
echo "编译好了：$APP"
