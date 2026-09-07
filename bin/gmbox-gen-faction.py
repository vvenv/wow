#!/usr/bin/env python3
"""Bake the realm's reputation factions into addons/GMBox/Data_Faction.lua.

Unlike the teleport and item tables, this one does not come from the world DB:
factions live in Faction.dbc. Two copies are read, because neither has both
halves of what the addon needs.

  * The server's extracted DBC (extracted-data/5875/dbc/Faction.dbc) is the
    authority on ids and on `reputationListID` -- a faction with -1 there is
    refused by `.modify rep` ("can'not have reputation"), so those are dropped.
    It came out of an enUS client, so only its English name column is filled.

  * The zhCN client's own copy, pulled straight out of patch-2.MPQ, carries the
    Chinese names in locale slot 4. Without it the tab still works; the list is
    just English-only.

Usage:  bin/gmbox-gen-faction.py   (bin/gmbox-gen-data.sh also calls it)
"""
import os, struct, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SERVER_DBC = os.path.join(ROOT, "vmangos-deploy/storage/mangosd/extracted-data/5875/dbc/Faction.dbc")
OUT = os.path.join(ROOT, "addons/GMBox/Data_Faction.lua")

# Highest-priority MPQ first; 1.12 resolves patch-2 over patch over dbc.
CLIENT_MPQS = [os.path.join(ROOT, "client-zhCN/Data", m)
               for m in ("patch-2.MPQ", "patch.MPQ", "dbc.MPQ")]

# 1.12 Faction.dbc, 37 fields:
#   0 id | 1 reputationListID | 2-5 raceMask | 6-9 classMask | 10-13 base
#   14-17 flags | 18 parentFaction | 19-26 name[8 locales] | 27 name flags
#   ... 28-36 description
NAME0 = 19
LOCALE_ZHCN = 4

try:
    from pypinyin import lazy_pinyin, Style
except ImportError:
    lazy_pinyin = None


def pinyin_index(name):
    """Same shape as gmbox-gen-data.py: "initials fullpinyin", "" for ASCII."""
    if not lazy_pinyin or not any(ord(c) > 0x2E80 for c in name):
        return ""
    keep = "".join(c for c in name if ord(c) > 0x2E80 or c.isalnum())
    if not keep:
        return ""
    full = "".join(c for c in "".join(lazy_pinyin(keep)) if c.isalnum()).lower()
    initials = "".join(c for c in "".join(lazy_pinyin(keep, style=Style.FIRST_LETTER))
                       if c.isalnum()).lower()
    if full == initials:
        return full
    return initials + " " + full


def parse(data):
    magic, rc, fc, rs, _ = struct.unpack("<4sIIII", data[:20])
    if magic != b"WDBC":
        raise ValueError("not a DBC")
    if fc < 27:
        raise ValueError("Faction.dbc has %d fields, expected the 1.12 layout" % fc)
    strings = data[20 + rc * rs:]

    def s(off):
        if not off:
            return ""
        end = strings.index(b"\0", off)
        return strings[off:end].decode("utf-8", "replace")

    out = {}
    for i in range(rc):
        f = struct.unpack_from("<%di" % fc, data, 20 + i * rs)
        out[f[0]] = {"rep": f[1], "names": [s(f[NAME0 + k]) for k in range(8)]}
    return out


def chinese_names():
    try:
        import mpyq
    except ImportError:
        print("pypi 'mpyq' not installed -- Chinese faction names skipped")
        return {}
    for path in CLIENT_MPQS:
        if not os.path.exists(path):
            continue
        try:
            blob = mpyq.MPQArchive(path).read_file("DBFilesClient\\Faction.dbc")
            if blob:
                rows = parse(blob)
                print("Chinese names from %s" % os.path.basename(path))
                return {fid: v["names"][LOCALE_ZHCN] for fid, v in rows.items()}
        except Exception as exc:                                # noqa: BLE001
            print("  %s: %s" % (os.path.basename(path), exc))
    print("no zhCN Faction.dbc found -- Chinese faction names skipped")
    return {}


# Which bucket a faction lands in on the addon's Reputation tab. Curated rather
# than derived from the DBC flags: the flags say "is this row drawn in the
# reputation pane", which is not the same question as "would a GM want to set
# this one". Anything not listed here falls out as group 6 (other).
#
#   1 Alliance capitals   2 Horde capitals   3 neutral hubs
#   4 grindable           5 battlegrounds    6 hidden / internal
#
# The "set them all to exalted" button covers 1-4 only. Battlegrounds are left
# out because both sides of a pair exist and exalting the enemy's is nonsense,
# and 67/469 (the Horde and Alliance umbrella factions) are left out because
# they are what NPC hostility keys off; group 6 rows are still settable one at
# a time from the list.
GROUPS = {
    1: (72, 47, 69, 54),
    2: (76, 81, 68, 530),
    3: (21, 369, 470, 577, 169),
    4: (529, 576, 609, 910, 749, 270, 59, 809, 349, 87, 70, 92, 93,
        589, 630, 909, 471, 574, 789, 629),
    5: (730, 729, 890, 889, 509, 510, 891, 892, 709),
}
GROUP_OF = {fid: g for g, ids in GROUPS.items() for fid in ids}


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    server = parse(open(SERVER_DBC, "rb").read())
    zh_all = chinese_names()

    rows = []
    for fid, v in server.items():
        if v["rep"] < 0:                     # CanHaveReputation() == false
            continue
        en = v["names"][0].strip()
        if not en:
            en = "Faction %d" % fid
        group = GROUP_OF.get(fid, 6)
        zh = (zh_all.get(fid) or "").strip()
        # The crafting-specialisation pseudo-factions occupy reputation slots
        # 22-33 and the two DBCs disagree about their names (the zhCN client
        # still holds whatever was in those rows before Blizzard reused them,
        # e.g. 46 reads "斯通纳德兽人" against the server's "Blacksmithing -
        # Armorsmithing"). The server's name is the one `.modify rep` reports
        # back, so for these the Chinese column is dropped rather than shown
        # against the wrong faction.
        if " - " in en and en.split(" - ")[0] in ("Blacksmithing", "Leatherworking", "Engineering"):
            zh, group = "", 6
        if zh == en:
            zh = ""
        rows.append((group, en, fid, zh, pinyin_index(zh)))

    rows.sort()

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("-- GMBox faction database -- generated from Faction.dbc (%d reputations).\n" % len(rows))
        f.write("-- Do not edit by hand; regenerate with bin/gmbox-gen-faction.py.\n")
        f.write("-- Entry layout: { id, name, zhName, pinyin, group }. The id is what\n")
        f.write("-- '.modify rep <id> <value>' expects; only factions with a\n")
        f.write("-- reputationListID are here, because the rest refuse the command.\n")
        f.write("-- group: 1 Alliance capitals, 2 Horde capitals, 3 neutral hubs,\n")
        f.write("--        4 grindable, 5 battlegrounds, 6 hidden / internal.\n\n")
        f.write("GMBox_Faction = {}\n\n")
        f.write("local t, n = GMBox_Faction, 0\n")
        f.write("local function A(a) for i = 1, table.getn(a) do n = n + 1; t[n] = a[i] end end\n\n")
        for i in range(0, len(rows), 8):
            chunk = rows[i:i + 8]
            f.write("A({" + ",".join(
                "{%d,%s,%s,%s,%d}" % (fid, q(en), q(zh), q(py), group)
                for group, en, fid, zh, py in chunk) + "})\n")

    named = sum(1 for r in rows if r[3])
    print("factions %d (%d with Chinese names) -> %s"
          % (len(rows), named, os.path.relpath(OUT, ROOT)))


if __name__ == "__main__":
    sys.exit(main())
