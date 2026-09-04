#!/usr/bin/env python3
"""Apply the travel/sightseeing/questing preset to a character's pfUI config.

pfUI keeps `pfUI_config` per character, in
  <client>/WTF/Account/<ACC>/<REALM>/<CHAR>/SavedVariables/pfUI.lua
so the preset has to be stamped onto every character separately. Run this with
the client CLOSED -- WoW rewrites SavedVariables wholesale on logout and would
throw the edit away.

Usage:  bin/pfui-travel-preset.py [path/to/pfUI.lua ...]     (no args = all)
        bin/pfui-travel-preset.py --dry-run
"""
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# path inside pfUI_config -> value.  Everything pfUI stores is a string.
PRESET = {
    # -- world map: the travel player's main screen -------------------------
    # draw the terrain of zones not visited yet, and mark the exploration
    # points, so the map is a place to plan a trip instead of a black void.
    ("appearance", "worldmap", "mapreveal"): "1",
    ("appearance", "worldmap", "mapexploration"): "1",

    # -- minimap: what you actually look at while walking -------------------
    ("appearance", "minimap", "size"): "170",       # 140 is small on 1440p
    ("appearance", "minimap", "zonetext"): "on",    # zone name always visible
    ("appearance", "minimap", "coordstext"): "on",  # coords always visible

    # -- quests -------------------------------------------------------------
    ("questlog", "showQuestLevels"): "1",

    # -- info panel: a single-player realm has no friends list to watch ------
    ("panel", "left", "right"): "bagspace",

    # -- travel journal: pfUI shoots the screenshot itself -------------------
    # hideui hides the whole interface for the shot, caption stamps timestamp
    # and "Zone - Subzone" on it.  loot "4" = epic only, so it stays rare.
    ("screenshot", "levelup"): "1",
    ("screenshot", "loot"): "4",
    ("screenshot", "caption"): "1",
    ("screenshot", "hideui"): "1",

    # -- modules that can never fire on this realm --------------------------
    ("disabled", "raid"): "1",                 # solo, no raid frames
    ("disabled", "targettargettarget"): "1",   # raid-parse frame
    ("disabled", "updatenotify"): "1",         # offline server, no update check

    # -- a little polish ----------------------------------------------------
    ("appearance", "border", "shadow"): "1",
}


def parse_value(s, i):
    """Parse one Lua value at s[i:]; return (value, next_index)."""
    if s[i] == '"':
        j = i + 1
        out = []
        while s[j] != '"':
            if s[j] == "\\":
                out.append(s[j:j + 2])
                j += 2
            else:
                out.append(s[j])
                j += 1
        return ("".join(out), j + 1)
    if s[i] == "{":
        return parse_table(s, i)
    m = re.compile(r"[^,\n]+").match(s, i)
    return (Raw(m.group().strip()), m.end())


class Raw(str):
    """A non-string Lua literal (number/boolean) kept verbatim."""


def parse_table(s, i):
    """Parse a Lua table starting at s[i] == '{'; return (dict, next_index)."""
    assert s[i] == "{"
    i += 1
    out = {}
    key_re = re.compile(r'\s*\["((?:[^"\\]|\\.)*)"\]\s*=\s*')
    while True:
        m = re.compile(r"\s*\}").match(s, i)
        if m:
            return (out, m.end())
        m = key_re.match(s, i)
        if not m:
            raise ValueError(f"unparsable at offset {i}: {s[i:i + 60]!r}")
        value, i = parse_value(s, m.end())
        out[m.group(1)] = value
        m = re.compile(r"\s*,").match(s, i)
        if m:
            i = m.end()


def dump(value, indent):
    if isinstance(value, dict):
        pad = "\t" * indent
        inner = "".join(
            f'{pad}\t["{k}"] = {dump(v, indent + 1)},\n' for k, v in value.items()
        )
        return "{\n" + inner + pad + "}"
    if isinstance(value, Raw):
        return str(value)
    return f'"{value}"'


def apply(path, dry_run=False):
    text = path.read_text(encoding="utf-8")
    m = re.search(r"^pfUI_config = (?=\{)", text, re.M)
    if not m:
        print(f"  {path}: no pfUI_config -- pfUI never ran for this character, skipped")
        return
    config, end = parse_table(text, m.end())

    changes = []
    for keypath, want in PRESET.items():
        node = config
        for key in keypath[:-1]:
            node = node.setdefault(key, {})
        have = node.get(keypath[-1])
        if have != want:
            changes.append(".".join(keypath) + f": {have!r} -> {want!r}")
            node[keypath[-1]] = want

    if not changes:
        print(f"  {path.parent.parent.name}: already up to date")
        return
    for c in changes:
        print(f"    {c}")
    if dry_run:
        return
    shutil.copy2(path, path.with_suffix(".lua.pre-travel-preset"))
    path.write_text(text[:m.end()] + dump(config, 0) + text[end:], encoding="utf-8")
    print(f"  {path.parent.parent.name}: {len(changes)} changed "
          f"(backup: {path.name}.pre-travel-preset)")


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry_run = "--dry-run" in sys.argv[1:]
    if args:
        targets = [Path(a) for a in args]
    else:
        targets = sorted(
            p for c in ("client", "client-zhCN")
            for p in (ROOT / c).glob("WTF/Account/*/*/*/SavedVariables/pfUI.lua")
        )
    if not targets:
        print("no pfUI.lua found -- log in once with pfUI enabled first")
        return 1
    for path in targets:
        print(f"==> {path.relative_to(ROOT)}")
        apply(path, dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
