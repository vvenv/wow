#!/usr/bin/env python3
"""向 mangosd 控制台发送命令（通过 pty attach，用 Ctrl-P Ctrl-Q 安全脱离）。

用法: mangos-console.py "account create foo bar" "account set gmlevel foo 6"

默认打线上那台（地址取仓库根目录 server.conf 里的 SERVER_HOST）。打本地那份用 SERVER_HOST=local。
线上走 ssh：优先用密钥，没配密钥就设 SERVER_SSH_PASSWORD=... 走 sshpass
（这台 sshd 目前 PubkeyAuthentication no，所以现在需要后者）。
"""
import os, pty, select, sys, time
from pathlib import Path


def server_conf(key, default=""):
    """读仓库根目录的 server.conf（KEY=VALUE，不入库，见 server.conf.example）。"""
    f = Path(__file__).resolve().parent.parent / "server.conf"
    if f.exists():
        for line in f.read_text().splitlines():
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() == key:
                return v.strip().strip('"').strip("'")
    return default


SERVER_HOST = server_conf("SERVER_HOST")

HOST = os.environ.get("SERVER_HOST", SERVER_HOST)
if not HOST:
    print("没有线上服地址：设 SERVER_HOST=<地址>，或在 server.conf 里填 SERVER_HOST；"
          "打本地那份用 SERVER_HOST=local。", file=sys.stderr)
    sys.exit(2)
LOCAL = HOST in ("local", "localhost", "127.0.0.1")
CONTAINER = "vmangos-deploy-mangosd-1" if LOCAL else "vmangos-mangosd-1"

cmds = sys.argv[1:]
if not cmds:
    print("usage: mangos-console.py <command> [command...]", file=sys.stderr); sys.exit(2)

docker_cmd = ["docker", "attach", "--detach-keys=ctrl-p,ctrl-q", CONTAINER]
if LOCAL:
    argv = docker_cmd
else:
    user = os.environ.get("SERVER_SSH_USER") or server_conf("SERVER_SSH_USER", "root")
    ssh = ["ssh", "-tt", "-o", "StrictHostKeyChecking=no", f"{user}@{HOST}"] + docker_cmd
    pw = os.environ.get("SERVER_SSH_PASSWORD")
    argv = ["sshpass", "-e"] + ssh if pw else ssh
    if pw:
        os.environ["SSHPASS"] = pw

pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)

out = []
def drain(timeout):
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                return
            if not d:
                return
            out.append(d.decode("utf-8", "replace"))

drain(3 if LOCAL else 8)
for c in cmds:
    os.write(fd, (c + "\n").encode())
    drain(4 if LOCAL else 6)
os.write(fd, b"\x10\x11")   # Ctrl-P Ctrl-Q -> detach
drain(2)
os.close(fd)
os.waitpid(pid, 0)
print("".join(out))
