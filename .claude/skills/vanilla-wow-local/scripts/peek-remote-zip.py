#!/usr/bin/env python3
"""不下载整个 ZIP，用 HTTP Range 读它的中央目录，列出内容；还能抽取小文件。

在决定是否投入数小时下载一个 5 GB 客户端包之前，先用它确认里面到底是什么：
是"解压即用"的 Data/*.MPQ，还是 Windows 安装程序（setup-N.bin，macOS 解不了）。
配合抽取 README / VERSION / SHA256SUMS，可以在下载前验明正身。

用法:
  peek-remote-zip.py <url>                  列出全部条目（按大小排序）
  peek-remote-zip.py <url> --get <路径> ...  取出指定的小文件并打印内容
"""
import struct, sys, time, urllib.request, zlib

UA = {"User-Agent": "Mozilla/5.0"}

def rng(url, a, b, tries=4):
    # 慢网络下大范围读容易 SSL 超时，重试几次
    last = None
    for attempt in range(tries):
        try:
            r = urllib.request.Request(url, headers=dict(UA, Range=f"bytes={a}-{b}"))
            return urllib.request.urlopen(r, timeout=120).read()
        except Exception as e:
            last = e
            time.sleep(2 * (attempt + 1))
    raise last

def size_of(url):
    r = urllib.request.Request(url, headers=UA, method="HEAD")
    return int(urllib.request.urlopen(r, timeout=60).headers["Content-Length"])

def central_dir(url, total):
    tail = rng(url, max(0, total - 1_000_000), total - 1)
    i = tail.rfind(b"PK\x05\x06")
    if i < 0:
        sys.exit("找不到 EOCD —— 不是 ZIP，或尾部超出 1 MB 探测范围")
    n, cd_size, cd_off = struct.unpack("<H", tail[i+10:i+12])[0], *struct.unpack("<II", tail[i+12:i+20])
    if 0xFFFFFFFF in (cd_size, cd_off) or n == 0xFFFF:      # ZIP64
        j = tail.rfind(b"PK\x06\x06")
        z = tail[j:j+56]
        n, cd_size, cd_off = struct.unpack("<Q", z[32:40])[0], struct.unpack("<Q", z[40:48])[0], struct.unpack("<Q", z[48:56])[0]
    return n, rng(url, cd_off, cd_off + cd_size - 1)

def parse(cd):
    ents, p = {}, 0
    while p < len(cd) and cd[p:p+4] == b"PK\x01\x02":
        method = struct.unpack("<H", cd[p+10:p+12])[0]
        csize, usize = struct.unpack("<II", cd[p+20:p+28])
        nlen, elen, clen = struct.unpack("<HHH", cd[p+28:p+34])
        lho = struct.unpack("<I", cd[p+42:p+46])[0]
        name = cd[p+46:p+46+nlen].decode("utf-8", "replace")
        extra = cd[p+46+nlen:p+46+nlen+elen]
        if 0xFFFFFFFF in (lho, csize, usize):                # ZIP64 extra
            q = 0
            while q + 4 <= len(extra):
                hid, hsz = struct.unpack("<HH", extra[q:q+4]); d = extra[q+4:q+4+hsz]; o = 0
                if hid == 1:
                    if usize == 0xFFFFFFFF: usize = struct.unpack("<Q", d[o:o+8])[0]; o += 8
                    if csize == 0xFFFFFFFF: csize = struct.unpack("<Q", d[o:o+8])[0]; o += 8
                    if lho   == 0xFFFFFFFF: lho   = struct.unpack("<Q", d[o:o+8])[0]
                q += 4 + hsz
        ents[name] = (lho, csize, usize, method)
        p += 46 + nlen + elen + clen
    return ents

def fetch(url, ents, name):
    lho, csize, _, method = ents[name]
    hdr = rng(url, lho, lho + 29)
    nl, el = struct.unpack("<HH", hdr[26:30])
    data = rng(url, lho + 30 + nl + el, lho + 30 + nl + el + csize - 1)
    return zlib.decompress(data, -15) if method == 8 else data

def main():
    url = sys.argv[1]
    total = size_of(url)
    n, cd = central_dir(url, total)
    ents = parse(cd)
    print(f"{url}\n  总大小 {total/1e9:.2f} GB，条目 {n} 个（已解析 {len(ents)}）\n")
    if "--get" in sys.argv:
        for name in sys.argv[sys.argv.index("--get") + 1:]:
            match = [k for k in ents if k.endswith(name)] or [name]
            for k in match[:1]:
                print(f"{'='*20} {k}")
                try: print(fetch(url, ents, k).decode("utf-8", "replace")[:4000])
                except Exception as e: print("读取失败:", e)
        return
    for name, (_, _, usize, _) in sorted(ents.items(), key=lambda x: -x[1][2])[:60]:
        print(f"{usize/1e6:10.1f} MB  {name}")

if __name__ == "__main__":
    main()
