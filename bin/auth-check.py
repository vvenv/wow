#!/usr/bin/env python3
"""独立验证 VMaNGOS 认证链路：SRP6 登录 + 领域列表 (vanilla 1.12.1 协议)。"""
import hashlib, socket, struct, sys, os

HOST = os.environ.get("SERVER_HOST", "127.0.0.1")  # SERVER_HOST=1.2.3.4 验证线上
PORT = int(os.environ.get("WOW_PORT", "3724"))
USER = sys.argv[1].upper() if len(sys.argv) > 1 else ""
PASS = sys.argv[2].upper() if len(sys.argv) > 2 else ""
if not USER or not PASS:
    sys.exit("用法: auth-check.py <账号> <密码>   （SERVER_HOST=<地址> 指定服务器）")
BUILD = 5875
INTEGRITY_HASH = bytes.fromhex("95EDB27C7823B363CBDDAB56A392E7CB73FCCA20")

def sha1(*parts):
    h = hashlib.sha1()
    for p in parts: h.update(p)
    return h.digest()

def to_le(n, size):  return n.to_bytes(size, "little")
def from_le(b):      return int.from_bytes(b, "little")

s = socket.create_connection((HOST, PORT), timeout=10)

# --- CMD_AUTH_LOGON_CHALLENGE ---
u = USER.encode()
body = (b"WoW\x00" + bytes([1, 12, 1]) + struct.pack("<H", BUILD)
        + b"68x\x00" + b"niW\x00" + b"SUne"
        + struct.pack("<I", 0) + struct.pack("<I", 0x0100007F)
        + bytes([len(u)]) + u)
s.sendall(bytes([0x00, 0x08]) + struct.pack("<H", len(body)) + body)

r = s.recv(4096)
if len(r) < 3: sys.exit(f"FAIL: 响应过短 {r!r}")
cmd, _, err = r[0], r[1], r[2]
if err != 0: sys.exit(f"FAIL: 服务器拒绝登录挑战, error=0x{err:02X}")
p = 3
B = from_le(r[p:p+32]); p += 32
glen = r[p]; p += 1
g = from_le(r[p:p+glen]); p += glen
Nlen = r[p]; p += 1
N = from_le(r[p:p+Nlen]); p += Nlen
salt = r[p:p+32]; p += 32
print(f"[挑战] OK  B={B:x}  g={g}  N_len={Nlen}")

# --- SRP6 ---
x = from_le(sha1(salt, sha1(f"{USER}:{PASS}".encode())))
a = from_le(os.urandom(19))
A = pow(g, a, N)
uu = from_le(sha1(to_le(A, 32), to_le(B, 32)))
k = 3
S = pow((B - k * pow(g, x, N)) % N, a + uu * x, N)
Sb = to_le(S, 32)
t1 = sha1(Sb[0::2]); t2 = sha1(Sb[1::2])
K = bytes(b for pair in zip(t1, t2) for b in pair)

hN = sha1(to_le(N, 32)); hg = sha1(to_le(g, 1))
xorNg = bytes(i ^ j for i, j in zip(hN, hg))
M1 = sha1(xorNg, sha1(USER.encode()), salt, to_le(A, 32), to_le(B, 32), K)
crc = sha1(to_le(A, 32), INTEGRITY_HASH)   # StrictVersionCheck 的版本证明

# --- CMD_AUTH_LOGON_PROOF ---
s.sendall(bytes([0x01]) + to_le(A, 32) + M1 + crc + bytes([0, 0]))
r = s.recv(4096)
if r[0] != 0x01: sys.exit(f"FAIL: 意外响应 cmd=0x{r[0]:02X}")
if r[1] != 0: sys.exit(f"FAIL: 登录证明被拒, error=0x{r[1]:02X}")
M2 = r[2:22]
expected = sha1(to_le(A, 32), M1, K)
print(f"[证明] OK  M2 校验={'通过' if M2 == expected else '不匹配'}")

# --- CMD_REALM_LIST ---
s.sendall(bytes([0x10]) + struct.pack("<I", 0))
r = s.recv(4096)
size = struct.unpack("<H", r[1:3])[0]
num = r[7]          # vanilla: uint32 unused + uint8 count
p = 8
print(f"[领域] 数量={num}")
for i in range(num):
    icon = struct.unpack("<I", r[p:p+4])[0]; p += 4
    flags = r[p]; p += 1
    e = r.index(b"\x00", p); name = r[p:e].decode(); p = e + 1
    e = r.index(b"\x00", p); addr = r[p:e].decode(); p = e + 1
    pop = struct.unpack("<f", r[p:p+4])[0]; p += 4
    chars, tz, _ = r[p], r[p+1], r[p+2]; p += 3
    print(f"        #{i+1} {name!r}  地址={addr}  在线人数={pop:.0f}  角色数={chars}  时区={tz}")
print("\n✅ 认证链路完全通过：账号密码正确，build 5875 通过 StrictVersionCheck，领域列表可拉取。")
