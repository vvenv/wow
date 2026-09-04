#!/usr/bin/env python3
"""Regenerate GMBox's baked-in databases from the running VMaNGOS world DB.

Usage:  bin/gmbox-gen-data.sh   (wrapper that dumps the TSVs and calls this)
"""
import os, re, sys

SP = sys.argv[1]
OUT = sys.argv[2]

# Typing Chinese into the 1.12 client under Wine does not work (the IME layer
# drops it and you get "?"), so every Chinese name also gets a pinyin index:
# "yamabu ymb" for 亚麻布, searchable with a plain ASCII keyboard.
try:
    from pypinyin import lazy_pinyin, Style
except ImportError:
    lazy_pinyin = None


def pinyin_index(name):
    if not lazy_pinyin or not any(ord(c) > 0x2E80 for c in name):
        return ""
    keep = "".join(c for c in name if ord(c) > 0x2E80 or c.isalnum())
    if not keep:
        return ""
    full = "".join(lazy_pinyin(keep))
    initials = "".join(lazy_pinyin(keep, style=Style.FIRST_LETTER))
    full = "".join(c for c in full if c.isalnum()).lower()
    initials = "".join(c for c in initials if c.isalnum()).lower()
    if full == initials:
        return full
    return initials + " " + full


def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


# One printable character per small number, for the per-item columns the addon
# filters on. The alphabet is ASCII 32..126 minus " and \, so a 17k-character
# literal needs no escaping and the addon can decode it with two comparisons:
#   b = byte(s, i); if b > 92 then b = b - 1 end; if b > 34 then b = b - 1 end
ALPHA = "".join(chr(c) for c in range(32, 127) if c not in (34, 92))
BASE = len(ALPHA)   # 93


def c1(v):
    """0..92 -> one character."""
    return ALPHA[max(0, min(v, BASE - 1))]


def c2(v):
    """0..8648 -> two characters, big endian. Used for the -1 = all masks."""
    v = max(0, min(v, BASE * BASE - 1))
    return ALPHA[v // BASE] + ALPHA[v % BASE]


# What the addon needs to know about an item to answer "can I wear this":
# armour weight, weapon, and the pieces every class can equip regardless.
# Cloaks are subclass 1 (cloth) in the DB, so slot beats subclass here.
UNIVERSAL_SLOTS = (2, 4, 11, 12, 16, 19)   # neck, shirt, finger, trinket, back, tabard
ARMOR_KIND = {0: "m", 1: "a", 2: "b", 3: "c", 4: "d", 6: "s", 7: "r", 8: "r", 9: "r"}
CLASS_KIND = {0: "p", 1: "g", 2: "w", 5: "p", 6: "j", 7: "t", 9: "e",
              11: "q", 12: "u", 13: "k", 15: "x"}


def kind_of(cls, sub, slot):
    if cls == 4:
        if slot in UNIVERSAL_SLOTS:
            return "m"
        return ARMOR_KIND.get(sub, "m")
    return CLASS_KIND.get(cls, ".")

def chunks(lst, n):
    for i in range(0, len(lst), n):
        yield lst[i:i + n]

# ---------------- items ----------------
ids, names, qual, zh = [], [], [], []
reqlvl, ilvl, kind, clsmask, racemask = [], [], [], [], []
for line in open(os.path.join(SP, "items.tsv"), encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    e, qq, nm = parts[0], parts[1], parts[2]
    cn = parts[3] if len(parts) > 3 else ""
    if cn == "NULL":
        cn = ""
    if not nm.strip():
        continue

    def col(i, default=0):
        try:
            return int(parts[i])
        except (IndexError, ValueError):
            return default

    ids.append(e)
    qual.append(min(int(qq), 7))
    names.append(nm)
    zh.append(cn if cn.strip() and cn != nm else "")
    reqlvl.append(c1(col(4)))
    ilvl.append(c1(col(5)))
    kind.append(kind_of(col(6), col(7), col(8)))
    # -1 means "no restriction"; store it as the all-bits value so the addon
    # only ever does a bit test and never a special case. Only the low bits
    # mean anything -- 1.12 has 9 classes and 8 races -- and the DB is full of
    # junk above them (32767 on 822 items), so mask before storing or those
    # items would look restricted to whoever happens to match the noise.
    cm, rm = col(9, -1) & 0x7FF, col(10, -1) & 0xFF
    clsmask.append(c2(2047 if cm == 0 else cm))
    racemask.append(c2(255 if rm == 0 else rm))

with open(os.path.join(OUT, "Data_Items.lua"), "w", encoding="utf-8") as f:
    f.write("-- GMBox item database -- generated from VMaNGOS item_template (%d items).\n" % len(ids))
    f.write("-- Do not edit by hand; regenerate with bin/gmbox-gen-data.sh.\n")
    f.write("-- The packed strings at the bottom hold one or two characters per item,\n")
    f.write("-- sharing the index of the tables above; see each one's comment.\n\n")
    f.write("GMBox_ItemID = {}\nGMBox_ItemName = {}\nGMBox_ItemNameZH = nil\nGMBox_ItemNamePY = nil\n\n")
    f.write("local dst, n = nil, 0\n")
    f.write("local function A(t) for i = 1, table.getn(t) do n = n + 1; dst[n] = t[i] end end\n\n")
    f.write("dst, n = GMBox_ItemID, 0\n")
    for c in chunks(ids, 500):
        f.write("A({" + ",".join(c) + "})\n")
    f.write("\ndst, n = GMBox_ItemName, 0\n")
    for c in chunks(names, 300):
        f.write("A({" + ",".join(q(x) for x in c) + "})\n")
    py = [pinyin_index(x) for x in zh]
    if any(py):
        f.write("\n-- Pinyin index for the Chinese names: initials, then full pinyin.\n")
        f.write("GMBox_ItemNamePY = {}\n")
        f.write("dst, n = GMBox_ItemNamePY, 0\n")
        for c in chunks(py, 400):
            f.write("A({" + ",".join(q(x) for x in c) + "})\n")

    if any(zh):
        f.write("\n-- Simplified Chinese names (locales_item.name_loc4); \"\" where the DB has none.\n")
        f.write("GMBox_ItemNameZH = {}\n")
        f.write("dst, n = GMBox_ItemNameZH, 0\n")
        for c in chunks(zh, 300):
            f.write("A({" + ",".join(q(x) for x in c) + "})\n")
    def packed(varname, chars, comment):
        s = "".join(chars)
        f.write("\n-- %s\n" % comment)
        f.write("%s = table.concat({\n" % varname)
        for i in range(0, len(s), 200):
            f.write('  "%s",\n' % s[i:i + 200])
        f.write("})\n")

    packed("GMBox_ItemQuality", [str(x) for x in qual],
           "One digit per item: the quality, 0 (poor) to 7 (heirloom).")
    packed("GMBox_ItemReqLvl", reqlvl, "Required level, one packed char per item.")
    packed("GMBox_ItemLvl", ilvl, "Item level, one packed char per item.")
    packed("GMBox_ItemKind", kind,
           "Category: a/b/c/d cloth/leather/mail/plate, s shield, m any-class "
           "armour, w weapon, g bag, q quiver, p consumable, j ammo, t trade "
           "good, e recipe, u quest, k key, x misc, . other.")
    packed("GMBox_ItemClass", clsmask,
           "Allowable class mask, two packed chars per item (2047 = anyone).")
    packed("GMBox_ItemRace", racemask,
           "Allowable race mask, two packed chars per item (255 = anyone).")

# ---------------- teleport names in Chinese ----------------
# game_tele holds English identifiers only (Ironforge, TarrenMill, brd), and no
# table in the world DB pairs them with the Chinese area names. pfQuest ships
# both languages keyed by the same area id, so match on a normalised name.
def zone_map(addons_dir):
    def zones(path):
        try:
            text = open(path, encoding="utf-8").read()
        except IOError:
            return {}
        return {int(i): n for i, n in re.findall(r'\[(\d+)\]="((?:[^"\\]|\\.)*)"', text)}

    en = zones(os.path.join(addons_dir, "pfQuest/db/enUS/zones.lua"))
    zh = zones(os.path.join(addons_dir, "pfQuest/db/zhCN/zones.lua"))
    out = {}
    for area_id, name in en.items():
        chinese = zh.get(area_id)
        if chinese:
            out.setdefault(norm(name), chinese)
    return out


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def chinese_for(tele_name, by_norm):
    key = norm(tele_name)
    if key in by_norm:
        return by_norm[key]
    # Composite names like AlteracValleyAlliance fall back to their longest
    # zone-name prefix, which is still what you would search for.
    best = ""
    for candidate in by_norm:
        if len(candidate) >= 4 and key.startswith(candidate) and len(candidate) > len(best):
            best = candidate
    if best:
        return by_norm[best]
    # And the other direction: game_tele says "Stormwind" where the zone table
    # says "Stormwind City". Take the shortest zone name that starts with it.
    if len(key) >= 5:
        for candidate in sorted(by_norm, key=len):
            if candidate.startswith(key):
                return by_norm[candidate]
    return ""


# ---------------- teleports ----------------
rows = []
for line in open(os.path.join(SP, "tele.tsv"), encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    nm, mp, x, y, z = line.split("\t")
    rows.append((nm, mp, x, y, z))

with open(os.path.join(OUT, "Data_Tele.lua"), "w", encoding="utf-8") as f:
    f.write("-- GMBox teleport database -- generated from VMaNGOS game_tele (%d locations).\n" % len(rows))
    f.write("-- Do not edit by hand; regenerate with bin/gmbox-gen-data.sh.\n")
    f.write("-- Entry layout: { name, map, x, y, z }. The name is what '.tele <name>' expects.\n\n")
    f.write("GMBox_Tele = {}\nGMBox_TeleZH = {}\nGMBox_TelePY = {}\n\n")
    f.write("local t, n = GMBox_Tele, 0\n")
    f.write("local function A(a) for i = 1, table.getn(a) do n = n + 1; t[n] = a[i] end end\n\n")
    for c in chunks(rows, 40):
        f.write("A({" + ",".join("{%s,%s,%s,%s,%s}" % (q(nm), mp, x, y, z) for nm, mp, x, y, z in c) + "})\n")

    by_norm = zone_map(os.path.dirname(OUT.rstrip("/")))
    zh_names = [chinese_for(r[0], by_norm) for r in rows]
    hits = sum(1 for x in zh_names if x)
    f.write("\n-- Chinese area names matched from pfQuest's zone tables, plus pinyin.\n")
    f.write("local t2, n2 = GMBox_TeleZH, 0\n")
    f.write("local function B(a) for i = 1, table.getn(a) do n2 = n2 + 1; t2[n2] = a[i] end end\n")
    for c in chunks(zh_names, 40):
        f.write("B({" + ",".join(q(x) for x in c) + "})\n")
    f.write("\nt2, n2 = GMBox_TelePY, 0\n")
    for c in chunks([pinyin_index(x) for x in zh_names], 40):
        f.write("B({" + ",".join(q(x) for x in c) + "})\n")
    print("tele with Chinese names: %d/%d" % (hits, len(rows)))

print("items %d, tele %d" % (len(ids), len(rows)))
