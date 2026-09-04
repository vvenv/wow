#!/usr/bin/env python3
"""Guard a null deref in 1.12.1 Player_C equipment-flag update (build 5875).

Crash (2026-09-04 11:28, WC AoE loot):
    ERROR #132 ACCESS_VIOLATION at 0x004C7F1B
    mov eax, [0xB71F60]
    mov dword [eax+edi], 0
0xB71F60 is a pointer to 12 DWORD equipment-slot flags. When it is NULL the
write kills the client; the same save then mailed the half-created items.

The write sits in a loop (edi 0..0x30) inside the function at 0x004C7EE0,
which allocates a scratch object first and ends in a plain `ret` -- no stack
args to clean up, and its EAX is not a constructed `this` (the existing
allocation-failed path at 0x004C808D returns early the same way). So bailing
out at the very top, before `push ebp`, is stack- and ABI-safe.

Layout: a jmp at the function entry goes to a cave in the .text raw padding,
which re-tests the pointer, replays the 9 prologue bytes the jmp overwrote,
and jumps back in. Null pointer -> plain ret, buffer untouched.

Idempotent. Re-run after vanilla-tweaks regenerates WoW_tweaked.exe. (The
--maxcameradistance tweak is vanilla-tweaks' own flag, not something this
script has to replay -- see the vanilla-tweaks section of the README.)
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

IMAGE_BASE = 0x400000
EXPECTED_SIZE = 4775986  # 1.12.1 build 5875; vanilla-tweaks patches in place
FN_VA = 0x004C7EE0
PTR_VA = 0x00B71F60
# push ebp; mov ebp,esp; push ecx; push 0x90 -- position-independent, so the
# cave can replay them verbatim. The 5-byte jmp only clobbers the first five.
STOLEN = bytes.fromhex("558bec516890000000")
FN_CONT_VA = FN_VA + len(STOLEN)  # 0x004C7EE9, the original `call operator new`
CAVE_MARK = struct.pack("<HIB", 0x3D83, PTR_VA, 0)  # cmp dword [PTR_VA], 0


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


def _text_off(target_va: int, va: int, rsize: int, raw: int) -> int:
    """File offset of a VA inside .text. Raises if it lands outside."""
    rva = target_va - IMAGE_BASE
    if not va <= rva < va + rsize:
        raise ValueError(f"0x{target_va:08X} is outside .text")
    return raw + rva - va


def _build_cave(cave_va: int) -> bytes:
    #   cmp dword [PTR_VA], 0
    #   jz  <ret>
    #   <STOLEN>
    #   jmp FN_CONT_VA
    #   ret
    cave = bytearray(CAVE_MARK)
    jz_at = len(cave)
    cave += b"\x74\x00"  # displacement filled in once the ret is placed
    cave += STOLEN
    cave += b"\xe9" + _rel32(cave_va + len(cave), FN_CONT_VA)
    cave[jz_at + 1] = len(cave) - (jz_at + 2)  # jz -> the ret below
    cave += b"\xc3"
    return bytes(cave)


def patch(path: Path) -> str:
    if not path.is_file():
        return f"{path}: not found, skipped"
    data = bytearray(path.read_bytes())
    if len(data) != EXPECTED_SIZE:
        return f"{path}: size {len(data)} != {EXPECTED_SIZE}, not a 1.12.1 build 5875 exe, skipped"
    hdr, vsize, va, rsize, raw = _pe_text(data)
    fn_off = _text_off(FN_VA, va, rsize, raw)

    if data[fn_off] == 0xE9:  # already redirected -- follow the jmp and check
        tgt = FN_VA + 5 + struct.unpack_from("<i", data, fn_off + 1)[0]
        try:
            cave_off = _text_off(tgt, va, rsize, raw)
        except ValueError as exc:
            return f"{path}: entry jmp leaves .text ({exc}), skipped"
        if data[cave_off : cave_off + len(CAVE_MARK)] == CAVE_MARK:
            return f"{path}: already patched (cave at 0x{tgt:08X})"
        return f"{path}: entry jmp points at unknown code 0x{tgt:08X}, skipped"

    if data[fn_off : fn_off + len(STOLEN)] != STOLEN:
        got = data[fn_off : fn_off + len(STOLEN)].hex()
        return f"{path}: prologue {got} != {STOLEN.hex()}, skipped"

    # Cave sits in .text raw padding (vsize..rsize). Bump VirtualSize so the
    # loader maps those bytes as part of the section.
    cave_off = raw + vsize
    cave_va = IMAGE_BASE + va + vsize
    cave = _build_cave(cave_va)
    if cave_off + len(cave) > raw + rsize:
        return f"{path}: only {raw + rsize - cave_off} bytes of .text padding, need {len(cave)}, skipped"

    # Refresh the backup on every real patch: vanilla-tweaks regenerates this
    # exe, so a stale copy would not be the pre-patch state of *this* one.
    path.with_suffix(path.suffix + ".pre-itemc-nullguard").write_bytes(data)

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
