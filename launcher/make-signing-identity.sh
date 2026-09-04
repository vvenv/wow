#!/usr/bin/env bash
# 造一个本机自签的代码签名身份，给 WoW.app 用。跑一次就够，之后 build.sh 自动认。
#
# 为什么需要它：辅助功能授权（原生全屏那条路要用）在 TCC 里是按「指定要求」
# 记的。ad-hoc 签名（codesign -s -）的指定要求是一串 cdhash：
#
#     designated => cdhash H"a9c806b0..."
#
# 二进制一变 cdhash 就变，授权立刻作废 —— 每改一次启动器都得重新授权一遍。
# 换成自签证书之后指定要求变成：
#
#     designated => identifier "dev.vvenv.wow.launcher"
#                   and certificate leaf = H"25674fc2..."
#
# 只跟证书绑定，重新编译多少次都不掉。
#
# 不需要 sudo，也不需要动「证书信任设置」—— codesign 按 SHA-1 引用身份时
# 不要求这张自签根是受信任的。
set -euo pipefail

CN="WoW Launcher Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CN" >/dev/null 2>&1; then
  SHA1=$(security find-certificate -c "$CN" -Z | awk '/SHA-1 hash:/{print $3}')
  echo "身份已存在：$CN"
  echo "  SHA-1: $SHA1"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cs.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = WoW Launcher Local Signing
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# 20 年，省得哪天过期了又来一遍
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$TMP/cs.key" -out "$TMP/cs.crt" -config "$TMP/cs.cnf" 2>/dev/null

# macOS 的 Security 框架读不了 LibreSSL 默认那套 PKCS#12 参数（导入时报
# 「MAC verification failed」），指定老算法 + 非空密码才能进钥匙串。
openssl pkcs12 -export -out "$TMP/cs.p12" -inkey "$TMP/cs.key" -in "$TMP/cs.crt" \
  -name "$CN" -passout pass:wowlauncher \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

security import "$TMP/cs.p12" -k "$KEYCHAIN" -P wowlauncher -T /usr/bin/codesign

SHA1=$(security find-certificate -c "$CN" -Z | awk '/SHA-1 hash:/{print $3}')
echo "身份造好了：$CN"
echo "  SHA-1: $SHA1"
echo
echo "现在重新跑一次 launcher/build.sh，然后在"
echo "  系统设置 → 隐私与安全性 → 辅助功能"
echo "里把 WoW.app 打开 —— 这次授权不会再被重新编译冲掉。"
