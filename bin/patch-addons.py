#!/usr/bin/env python3
"""Local fixes for upstream addon bugs, most of which only bite a zhCN client.

Called at the end of bin/install-addons.sh so a reinstall does not lose them.
Every patch is idempotent and prints what it did.

  1. Atlas   -- every locale file REPLACES the AtlasLocale table instead of
                merging into it, and the Chinese translation is from an older
                Atlas, so 312 keys the map data references are simply absent.
                AtlasMaps.lua then does `nil .. "text"`:
                  AtlasMaps.lua:79: attempt to concatenate field
                  'Mysterious Wailing Caverns Chest' (a nil value)
                Fix: append the missing keys (English text) to the zhCN table.

  2. Bagshui -- ActiveQuestItems.lua parses quest objectives with the ASCII
                pattern "(.+): (%d+)/(%d+)". Chinese objectives use a fullwidth
                colon (U+FF1A, UTF-8 EF BC 9A), so the match fails, itemName is
                nil, and `self.items[nil] = ...` throws on every quest update:
                  ActiveQuestItems.lua:122: table index is nil
                Fix: normalise the colon (the same thing pfQuest does) and skip
                the entry when the objective still does not parse.

  3. AtlasLoot -- the zhCN locale file came from a TBC-era AtlasLoot and
                carries 200+ keys this 1.12 backport never defines, which
                AceLocale-2.2 rejects one "Improper translation exists" error
                at a time. Fix: comment out the keys with no enUS counterpart.

  4. Bagshui.xml -- includes Components\\Ui.Skin.lua, a file 1.0.5 never
                shipped, so FrameXML logs `Error loading ...\\Ui.Skin.lua` at
                every login. Fix: drop the include; Components/Skins.lua, which
                is included further down, already does the skin setup.
"""
import os, re, sys

BEGIN = "-- >>> local patch (bin/patch-addons.py) -- do not edit by hand"
END = "-- <<< end local patch"


def read(p):
    return open(p, encoding="utf-8", errors="surrogateescape").read()


def write(p, s):
    open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)


# Pairs look like  ["Foo"] = "Bar";  and a single line may hold more than one
# of them (Atlas-enUS.lua really does that), so scan the whole text, not lines.
PAIR = re.compile(r'\["((?:[^"\\]|\\.)*)"\]\s*=\s*("(?:[^"\\]|\\.)*")\s*;')


def locale_keys(path):
    """{key: quoted lua string value}"""
    return {m.group(1): m.group(2) for m in PAIR.finditer(read(path))}


REF = re.compile(r'AtlasLocale\["((?:[^"\\]|\\.)*)"\]')
# `ATLAS_FOO = "bar";` at the start of a line, and any use of such a name.
# The value may be an expression such as  GREN.."Battlegrounds"  where GREN is a
# file-local colour code, so capture the whole right-hand side and resolve those
# locals to their literals before re-emitting them elsewhere.
GLOBAL_DEF = re.compile(r'^\s*(ATLAS_[A-Za-z0-9_]+)\s*=\s*(.+?);\s*$', re.M)
LOCAL_STR = re.compile(r'^\s*local\s+([A-Za-z_]\w*)\s*=\s*("(?:[^"\\]|\\.)*")\s*;', re.M)
LITERAL_ONLY = re.compile(r'^\s*"(?:[^"\\]|\\.)*"(?:\s*\.\.\s*"(?:[^"\\]|\\.)*")*\s*$')
GLOBAL_REF = re.compile(r'\b(ATLAS_[A-Za-z0-9_]+)\b')


def patch_atlas(addons):
    """Give the zhCN table an entry for every key the Atlas code looks up.

    The reference set comes from the code, not from Atlas-enUS.lua, because two
    keys ("Naxx", "Ulda") are referenced but defined in no locale file at all --
    those would break an English client too.
    """
    base = os.path.join(addons, "Atlas")
    en = os.path.join(base, "Locale/Atlas-enUS.lua")
    zh = os.path.join(base, "Locale/Atlas-zhCN.lua")
    if not (os.path.exists(en) and os.path.exists(zh)):
        return "Atlas: locale files not found, skipped"

    src = read(zh)
    # drop a previous run's block first, and count keys from THAT text -- reading
    # the file back would count the previous run's own additions as present.
    src = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n", "", src, flags=re.S)
    have = {k for k, _ in PAIR.findall(src)}

    english = locale_keys(en)
    refs = set()
    for name in sorted(os.listdir(base)):
        if name.endswith(".lua"):
            refs |= set(REF.findall(read(os.path.join(base, name))))

    missing = sorted(k for k in refs if k not in have)
    if not missing:
        write(zh, src)
        return "Atlas: nothing missing"

    lines = src.rstrip("\n").splitlines()
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip() == "end":
            break
    else:
        return "Atlas: could not find the closing `end`, skipped"

    block = [BEGIN,
             "-- Keys that Atlas's own code looks up but this locale never defines;",
             "-- without them AtlasMaps.lua concatenates nil. English text is the fallback.",
             "if AtlasLocale then"]
    for k in missing:
        block.append('\tAtlasLocale["%s"] = %s;' % (k, english.get(k, '"%s"' % k)))
    block.append("end")

    # Same story one level up: the dropdown tables are indexed by ATLAS_* string
    # globals, and a missing one makes the table constructor itself fail with
    # "AtlasDropDown.lua:66: table index is nil".
    en_text = read(en)
    en_locals = dict(LOCAL_STR.findall(en_text))
    en_globals = []
    for name, rhs in GLOBAL_DEF.findall(en_text):
        for local_name, literal in en_locals.items():
            rhs = re.sub(r"\b%s\b" % re.escape(local_name), literal, rhs)
        if LITERAL_ONLY.match(rhs):
            en_globals.append((name, rhs.strip()))
    zh_globals = {name for name, _ in GLOBAL_DEF.findall(src)}
    used = set()
    for name in sorted(os.listdir(base)):
        if name.endswith(".lua") or name.endswith(".xml"):
            used |= set(GLOBAL_REF.findall(read(os.path.join(base, name))))
    glob_missing = [(n, v) for n, v in en_globals if n in used and n not in zh_globals]
    if glob_missing:
        block.append("-- String globals the dropdown menus are indexed by.")
        for n, v in glob_missing:
            block.append('if not %s then %s = %s; end' % (n, n, v))

    block += [END]

    lines[i:i] = block
    write(zh, "\n".join(lines) + "\n")
    return "Atlas: added %d fallback keys + %d string globals to Atlas-zhCN.lua" % (
        len(missing), len(glob_missing))


def patch_bagshui_xml(addons):
    """Drop the include for Ui.Skin.lua — that file was never in 1.0.5.

    FrameXML logs `Error loading ...\\Ui.Skin.lua` every login. Skin setup
    already lives in Components/Skins.lua, which is included later.
    """
    p = os.path.join(addons, "Bagshui/Bagshui.xml")
    if not os.path.exists(p):
        return "Bagshui.xml: not found, skipped"
    src = read(p)
    old = '<Include file="Components\\Ui.Skin.lua" />'
    new = "<!-- Ui.Skin.lua was never shipped in 1.0.5; Skins.lua covers this. -->"
    if new in src:
        return "Bagshui.xml: Ui.Skin.lua include already removed"
    if old not in src:
        # Do not report success just because the exact tag is absent -- an
        # upstream reformat (or a release that finally ships the file) has to
        # be visible, not silently swallowed.
        if "Ui.Skin.lua" in src:
            return "Bagshui.xml: Ui.Skin.lua still referenced but the include line changed, CHECK BY HAND"
        return "Bagshui.xml: no Ui.Skin.lua include, nothing to do"
    write(p, src.replace(old, new))
    return "Bagshui.xml: removed missing Ui.Skin.lua include"


def patch_bagshui(addons):
    p = os.path.join(addons, "Bagshui/Components/ActiveQuestItems.lua")
    if not os.path.exists(p):
        return "Bagshui: ActiveQuestItems.lua not found, skipped"
    src = read(p)
    if "239\\188\\154" in src:
        return "Bagshui: already patched"

    pat = re.compile(
        r'([ \t]*)_, _, itemName, numObtained, numNeeded = string\.find\(objectiveText, "\(\.\+\): \(%d\+\)/\(%d\+\)"\)\n'
        r'([ \t]*)self\.items\[itemName\] = \{\n(.*?)\n([ \t]*)\}\n', re.S)
    m = pat.search(src)
    if not m:
        return "Bagshui: parse block not found (upstream changed?), skipped"

    ind, ind2, body, ind3 = m.group(1), m.group(2), m.group(3), m.group(4)
    body = "\n".join("\t" + ln for ln in body.splitlines())
    new = (
        f'{ind}-- Local patch: zhCN/zhTW quest objectives use a fullwidth colon\n'
        f'{ind}-- (U+FF1A, UTF-8 EF BC 9A), so the ASCII pattern below matched nothing,\n'
        f'{ind}-- itemName came back nil and self.items[nil] threw "table index is nil".\n'
        f'{ind}-- Normalising the colon is what pfQuest does for the same text.\n'
        f'{ind}_, _, itemName, numObtained, numNeeded =\n'
        f'{ind}\tstring.find(string.gsub(objectiveText, "\\239\\188\\154", ":"), "(.+):%s*(%d+)/(%d+)")\n'
        f'{ind}if itemName then\n'
        f'{ind2}\tself.items[itemName] = {{\n{body}\n{ind3}\t}}\n'
        f'{ind}end\n')
    write(p, src[:m.start()] + new + src[m.end():])
    return "Bagshui: quest-objective parsing made locale-safe"


ACE_KEY = re.compile(r'\["((?:[^"\\]|\\.)*)"\]\s*=')


def _ace_keys(text):
    """Keys from an AceLocale table, ignoring commented-out lines."""
    out = set()
    for line in text.splitlines():
        if re.match(r"\s*--", line):
            continue
        m = ACE_KEY.search(line)
        if m:
            out.add(m.group(1))
    return out


def patch_atlasloot(addons):
    """Drop Chinese entries that have no counterpart in the English base table.

    AtlasLoot uses AceLocale-2.2, which refuses any translation key that is not
    in the base (enUS) table:

      locale.cn.lua:11: AceLocale(AtlasLoot): Improper translation exists,
      "Robotic Homing Chicken" is likely misspelled for locale zhCN.

    The Chinese file came from a later, TBC-era AtlasLoot, so it carries 200+
    keys this 1.12 backport never defines. Commenting them out is lossless:
    they name content that does not exist here.
    """
    base = os.path.join(addons, "AtlasLoot", "Locale")
    en = os.path.join(base, "locale.en.lua")
    cn = os.path.join(base, "locale.cn.lua")
    if not (os.path.exists(en) and os.path.exists(cn)):
        return "AtlasLoot: locale files not found, skipped"

    known = _ace_keys(read(en))
    out, dropped = [], 0
    for line in read(cn).splitlines():
        if not re.match(r"\s*--", line):
            m = ACE_KEY.search(line)
            if m and m.group(1) not in known:
                indent = line[:len(line) - len(line.lstrip())]
                line = indent + "-- [not in locale.en.lua] " + line.lstrip()
                dropped += 1
        out.append(line)
    if dropped == 0:
        return "AtlasLoot: nothing to drop"
    write(cn, "\n".join(out) + "\n")
    return "AtlasLoot: commented out %d keys the enUS base table does not have" % dropped


def main():
    addons = sys.argv[1]
    for line in (patch_atlas(addons), patch_atlasloot(addons), patch_bagshui(addons), patch_bagshui_xml(addons)):
        print("    " + line)


if __name__ == "__main__":
    main()
