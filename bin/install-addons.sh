#!/usr/bin/env bash
# Install the vetted 1.12.1 addon set into client/Interface/AddOns.
#
# Every entry below was checked to declare "## Interface: 11200" (vanilla 1.12).
# Classic-Era addons (Questie, DBM, Bagnon, Auctionator, BigFoot ... anything
# built for 1.13+) will NOT load here, no matter the "load out of date" tick --
# the Lua API they call does not exist in 1.12.
#
# This realm is a single-player local server, so group/raid tooling is left out
# on purpose: no damage meter (DPSMate), no threat meter, no rare-spawn scanner
# (unitscan) -- with GM commands you spawn or teleport to whatever you want.
#
# Sources are pinned to the commit/tag that was verified; bump them by hand.
# Usage:  bin/install-addons.sh [addon-name ...]     (no args = all)
#         DEST=/somewhere bin/install-addons.sh      (another client folder)
#         LOCALE=zhCN DEST=... bin/install-addons.sh  (Chinese client)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Both clients' Interface/AddOns are symlinks to this one directory: the addons
# are identical for either language (pfQuest's zhCN build carries both locales),
# so one install serves both and they cannot drift apart.
DEST="${DEST:-$ROOT/addons}"
# pfQuest ships one build per client language; the rest are language-agnostic
# (shagu's addons carry all locales, the others have ASCII-only UI).
LOCALE="${LOCALE:-enUS}"

# name | archive url | path inside archive | notes
ADDONS=(
  "pfQuest|https://github.com/shagu/pfQuest/releases/download/7.0.1/pfQuest-$LOCALE.zip|pfQuest|quest + npc/item/object database, map and minimap markers"
  "Bagshui|https://codeload.github.com/absir/Bagshui/tar.gz/05d269b|Bagshui-*|one-bag inventory with automatic categories (v1.0.5 by veechs; this is a mirror)"
  "Atlas|https://codeload.github.com/Cabro/Atlas/tar.gz/895ddde|Atlas-*/Atlas|dungeon maps"
  "AtlasLoot|https://codeload.github.com/Cabro/Atlas/tar.gz/895ddde|Atlas-*/AtlasLoot|boss loot tables"
  "AtlasQuest|https://codeload.github.com/Cabro/Atlas/tar.gz/895ddde|Atlas-*/AtlasQuest|dungeon quests"
  "SuperMacro|https://codeload.github.com/Monteo/SuperMacro/tar.gz/2ca8239|SuperMacro-*|longer macros, macro library, /run helpers"

  # -- full UI replacement -------------------------------------------------
  # pfUI is the UI now, so everything it already contains was dropped from this
  # list on 2026-09-03: ShaguPlates (it *is* pfUI's nameplate module, exported
  # standalone), ShaguTweaks + -extras (tweaks for the default UI pfUI replaces
  # wholesale), ShaguValue, ShaguError, ShaguMount and ShaguBoP. pfUI names all
  # of them in the softconflict table of modules/addoncompat.lua and would ask
  # to disable them on every login. The retired entries, still pinned to the
  # commits that were verified, in case a plain default UI is ever wanted again:
  # "ShaguTweaks|https://codeload.github.com/shagu/ShaguTweaks/tar.gz/7d67021|ShaguTweaks-*|modular tweaks to the default UI (map coords, cooldown numbers, sell junk...)"
  # "ShaguPlates|https://codeload.github.com/shagu/ShaguPlates/tar.gz/9b2ebdf|ShaguPlates-*|nameplates: class colours, castbars, scaling"
  # "ShaguBoP|https://codeload.github.com/shagu/ShaguBoP/tar.gz/0aa4137|ShaguBoP-*|auto-confirm bind-on-pickup loot when alone (single-player gold)"
  # "ShaguError|https://codeload.github.com/shagu/ShaguError/tar.gz/da847ea|ShaguError-*|hide the red error popups"
  # "ShaguMount|https://codeload.github.com/shagu/ShaguMount/tar.gz/e688d31|ShaguMount-*|auto-dismount when using an action that requires it"
  # "ShaguValue|https://codeload.github.com/shagu/ShaguValue/tar.gz/debbde8|ShaguValue-*|item sell/buy values on tooltips"
  # "ShaguTweaks-extras|https://codeload.github.com/shagu/ShaguTweaks-extras/tar.gz/e5140e5|ShaguTweaks-extras-*|extra modules for ShaguTweaks"

  # -- retired 2026-09-03: this is a travel / sightseeing / questing character --
  # The playstyle is walking around, looking at things, doing quests and the
  # occasional dungeon, so the numbers half of the list went. Every entry is
  # commented out rather than deleted -- URL and commit still pinned, uncomment
  # to get it back. A tarball of the folders is in addons-removed-*.tar.gz.
  #   ShaguDPS                  damage meter -- put it back if dungeon numbers matter
  #   ShaguScore                gearscore -- GMBox spawns any item anyway
  #   ShaguInventory            cross-character item counts -- one character
  #   BetterCharacterStats      spell power / hit / crit -- a stats sheet
  #   ItemRack                  gear set swapping -- one set is enough
  #   AdvancedTradeSkillWindow  craft queues -- gathering needs no craft window
  #   pfStudio                  in-game Lua IDE -- a dev tool, not a game addon
  # The whole Atlas trio (Atlas + AtlasLoot + AtlasQuest) stays: dungeons are
  # still on the menu, so maps, boss loot tables and dungeon quests all earn
  # their place. Only the raid-scale and numbers tooling went.

  "pfUI|https://codeload.github.com/shagu/pfUI/tar.gz/b2f6df8|pfUI-*|complete UI replacement: unitframes, actionbars, bags, chat, nameplates, minimap"

  # -- solo flavour --------------------------------------------------------
  "ShaguNotify|https://codeload.github.com/shagu/ShaguNotify/tar.gz/2ecb31e|ShaguNotify-*|achievement-style popups for level ups, new skills, rare loot"
  "ShaguKill|https://codeload.github.com/shagu/ShaguKill/tar.gz/498e2db|ShaguKill-*|remaining kills until the next level"
  # "ShaguScore|https://codeload.github.com/shagu/ShaguScore/tar.gz/b07d25e|ShaguScore-*|gearscore-like item rating"

  # -- fewer clicks --------------------------------------------------------

  # -- numbers -------------------------------------------------------------
  # "ShaguDPS|https://codeload.github.com/shagu/ShaguDPS/tar.gz/79c25e6|ShaguDPS-*|lightweight damage meter"
  # "ShaguInventory|https://codeload.github.com/shagu/ShaguInventory/tar.gz/00eeeb2|ShaguInventory-*|item counts across all characters on tooltips"

  # -- map and tinkering ---------------------------------------------------
  "pfQuest-icons|https://codeload.github.com/shagu/pfQuest-icons/tar.gz/709ba27|pfQuest-icons-*|Gatherer-style icons for pfQuest resource nodes"
  # "pfStudio|https://codeload.github.com/shagu/pfStudio/tar.gz/01e1dac|pfStudio-*|in-game Lua IDE"

  # -- what pfUI does not do ------------------------------------------------
  # Picked to fill the gaps pfUI leaves; pfUI carries explicit integration code
  # for the first two (see pfUI/modules/thirdparty-vanilla.lua).
  # "BetterCharacterStats|https://codeload.github.com/yutsuku/BetterCharacterStats/tar.gz/20fe849|BetterCharacterStats-*|spell power, hit, crit, mp5, defense on the character sheet -- 1.12 hides all of it"
  "CleverMacro|https://codeload.github.com/DanielAdolfsson/CleverMacro/tar.gz/7b85b4c|CleverMacro-*|conditional macros ([mod:alt], [harm], [stance]) for 1.12; complements SuperMacro"
  # "AdvancedTradeSkillWindow|https://codeload.github.com/laytya/AdvancedTradeSkillWindow-vanilla/tar.gz/9f405f0|AdvancedTradeSkillWindow-vanilla-*/AdvancedTradeSkillWindow|tradeskill window with craft queues and missing-reagent counts"
  # The addon sits at the archive root; the ItemRackFu subdirectory is a FuBar
  # plugin we have no FuBar for and is stripped by the cleanup rm below.
  # "ItemRack|https://codeload.github.com/McPewPew/ItemRack/tar.gz/8592f37|ItemRack-*|equipment set swapping plus an on-use trinket queue"
)

want=("$@")
mkdir -p "$DEST"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

for entry in "${ADDONS[@]}"; do
  IFS='|' read -r name url path notes <<<"$entry"
  if [ ${#want[@]} -gt 0 ]; then
    found=0; for w in "${want[@]}"; do [ "$w" = "$name" ] && found=1; done
    [ $found -eq 1 ] || continue
  fi
  echo "==> $name  ($notes)"
  work="$tmp/$name"; mkdir -p "$work"
  # Download first, then extract: bsdtar stops reading a .zip at its central
  # directory, which SIGPIPEs a `curl | bsdtar` pipeline into a spurious failure.
  curl -sSL -m 300 -o "$work/archive" "$url"
  bsdtar -xf "$work/archive" -C "$work"
  rm -f "$work/archive"
  # shellcheck disable=SC2086
  for src in $work/$path; do
    [ -d "$src" ] || { echo "    !! $src not found in archive"; exit 1; }
    target="$DEST/$name"
    rm -rf "$target"
    cp -R "$src" "$target"
    rm -rf "$target/.git" "$target/.github" "$target/Debug" "$target/ItemRackFu"
    n="$(basename "$target")"
    [ -f "$target/$n.toc" ] || echo "    !! $n has no $n.toc -- the client will ignore it"
    # Some addons ship the .toc with a UTF-8 BOM. The 1.12 parser then does not
    # recognise the "## Interface" line and flags the addon as out of date.
    [ -f "$target/$n.toc" ] && perl -i -pe 's/^\x{ef}\x{bb}\x{bf}// if $. == 1' "$target/$n.toc"
    # -m1 rather than `| head -1`: under `pipefail` the early close SIGPIPEs grep
    iface="$(grep -i -m1 '^## Interface' "$target/$n.toc" 2>/dev/null | tr -d '\r' || true)"
    echo "    $n  ${iface:-<no interface line>}"
  done
done
# Local fixes for upstream addon bugs (see bin/patch-addons.py). Run after every
# install so a reinstall does not silently bring the bugs back.
if [ -f "$ROOT/bin/patch-addons.py" ]; then
  echo "==> local patches"
  python3 "$ROOT/bin/patch-addons.py" "$DEST"
fi

echo
echo "Restart the client completely -- new addons are only enumerated at launch."
