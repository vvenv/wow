#!/usr/bin/env python3
"""向 mangosd 控制台发送命令。

docker attach 需要真 TTY，直接管道会报
"cannot attach stdin to a TTY-enabled container"。这里用 pty 包一层，
发完命令以 Ctrl-P Ctrl-Q 安全脱离（不会杀掉容器）。

用法: mangos-console.py "account create foo bar" "account set gmlevel foo 6"
环境变量 MANGOSD_CONTAINER 可覆盖容器名。
"""
import os, pty, select, sys, time

CONTAINER = os.environ.get("MANGOSD_CONTAINER", "vmangos-deploy-mangosd-1")
cmds = sys.argv[1:]
if not cmds:
    print("usage: mangos-console.py <command> [command...]", file=sys.stderr); sys.exit(2)

pid, fd = pty.fork()
if pid == 0:
    os.execvp("docker", ["docker", "attach", "--detach-keys=ctrl-p,ctrl-q", CONTAINER])

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

drain(3)
for c in cmds:
    os.write(fd, (c + "\n").encode())
    drain(4)
os.write(fd, b"\x10\x11")   # Ctrl-P Ctrl-Q -> detach
drain(2)
os.close(fd)
os.waitpid(pid, 0)
print("".join(out))
