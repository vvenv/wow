#!/usr/bin/env python3
"""Guard a null deref in 1.12.1 Player_C equipment-flag update (build 5875).

Crash (2026-09-04 11:28, WC AoE loot):
    ERROR #132 ACCESS_VIOLATION at 0x004C7F1B
    mov eax, [0xB71F60]
    mov dword [eax+edi], 0
0xB71F60 is a pointer to 12 DWORD equipment-slot flags. When it is NULL the
write kills the client; the same save then mailed the half-created items.

This function is reached from Item_C construction (loot / inventory update).
If the pointer is null, return without touching the buffer.

Idempotent. Re-run after vanilla-tweaks regenerates WoW_tweaked.exe.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

IMAGE_BASE = 0x400000
FN_VA = 0x004C7EE0
FN_CONT_VA = 0x004C7EE9  # original `call operator new` after `push 0x90`
PTR_VA = 0x00B71F60
ORIG_PROLOGUE = bytes.fromhex("558bec5168")  # push ebp; mov ebp,esp; push ecx; push imm32 first byte
CAVE_MARK = bytes.fromhex("833d601fb70000")  # cmp dword [0xB71F60], 0


def _pe_text(data: bytes):
    e = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, e + 6)[0]
    optsz = struct.unpack_from("<H", data, e + 20)[0]
    sec = e + 24 + optsz
    for i in range(nsec):
        o = sec + i * 40
        name = data[o : o + 8].split(b"\0")[0]
        if name == b".text":
            vsize, va, rsize, raw = struct.unpack_from("<IIII", data, o + 8)
            return o, vsize, va, rsize, raw
    raise SystemExit("no .text section")


def _rel32(src_va: int, dest_va: int) -> bytes:
    return struct.pack("<i", dest_va - (src_va + 5))


def patch(path: Path) -> str:
    data = bytearray(path.read_bytes())
    hdr, vsize, va, rsize, raw = _pe_text(data)
    fn_off = FN_VA - IMAGE_BASE  # .text raw == va, file off == rva
    if data[fn_off : fn_off + 5] != ORIG_PROLOGUE and data[fn_off] == 0xE9:
        cave_off = raw + vsize
        # already patched: accept either current or previous cave location
        if data[fn_off + 5 : fn_off + 10] and CAVE_MARK in bytes(data[raw + vsize - 64 : raw + rsize]):
            return f"{path}: already patched"
        # jmp already there — check mark anywhere in tail padding
        tail = bytes(data[raw + 0x3FDD00 : raw + rsize])
        if CAVE_MARK in tail:
            return f"{path}: already patched"
        return f"{path}: unexpected prologue {data[fn_off:fn_off+5].hex()}, skipped"

    if data[fn_off : fn_off + 5] != ORIG_PROLOGUE:
        return f"{path}: prologue {data[fn_off:fn_off+5].hex()} != {ORIG_PROLOGUE.hex()}, skipped"

    # Cave sits in .text raw padding (vsize..rsize). Bump VirtualSize so the
    # loader maps those bytes as part of the section.
    cave_off = raw + vsize
    cave_va = IMAGE_BASE + va + vsize
    if cave_off + 32 > raw + rsize:
        return f"{path}: not enough .text padding for cave, skipped"

    # cmp dword [0xB71F60], 0
    # jz +0x0E          ; to ret
    # push ebp
    # mov ebp, esp
    # push ecx
    # push 0x90
    # jmp FN_CONT_VA
    # ret
    cave = bytearray()
    cave += CAVE_MARK
    cave += bytes([0x74, 0x0E])
    cave += bytes.fromhex("558bec516890000000")
    cave += b"\xe9" + _rel32(cave_va + 18, FN_CONT_VA)
    cave += b"\xc3"
    assert len(cave) == 24

    bak = path.with_suffix(path.suffix + ".pre-itemc-nullguard")
    if not bak.exists():
        bak.write_bytes(data)

    data[cave_off : cave_off + len(cave)] = cave
    data[fn_off : fn_off + 5] = b"\xe9" + _rel32(FN_VA, cave_va)
    struct.pack_into("<I", data, hdr + 8, vsize + len(cave))
    path.write_bytes(data)
    return f"{path}: patched (cave at 0x{cave_va:08X})"


def main():
    if len(sys.argv) < 2:
        print("usage: patch-itemc-nullguard.py <WoW_tweaked.exe> [...]", file=sys.stderr)
        sys.exit(2)
    for a in sys.argv[1:]:
        print(patch(Path(a)))


if __name__ == "__main__":
    main()
