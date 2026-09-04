#!/usr/bin/env bash
# Convert a character to a Tauren Druid (race 6, class 11).
#
# VMaNGOS has no .changerace/.changeclass command -- the command table only
# offers `rename` -- so this edits the characters database directly. The
# character MUST be logged out: mangosd keeps an online character in memory and
# would write the old values back on save.
#
# Kept: level, xp, money, bags and equipment, quest history, reputation, skills.
# Rebuilt: spells (talents live in character_spell too), action bar, auras --
# replaced with the Tauren Druid starting set from playercreateinfo_*.
#
#   bin/character-to-druid.sh [character name]      (default: Alice)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-Alice}"
RACE=6      # Tauren
CLASS=11    # Druid
cd "$ROOT/vmangos-deploy"

sql() { docker compose exec -T database sh -c "mariadb -umangos -pmangos -N -e \"$1\"" 2>/dev/null | tr -d '\r'; }

read -r GUID ONLINE OLDRACE OLDCLASS LEVEL <<<"$(sql "select guid, online, race, class, level from characters.characters where name='$NAME';")"
[ -n "${GUID:-}" ] || { echo "no character named $NAME" >&2; exit 1; }
[ "$ONLINE" = "0" ] || { echo "$NAME is still logged in -- log out first" >&2; exit 1; }
[ "$OLDCLASS" != "$CLASS" ] || { echo "$NAME is already a druid, nothing to do"; exit 0; }
echo "$NAME (guid $GUID): race $OLDRACE -> $RACE, class $OLDCLASS -> $CLASS, level $LEVEL"

BACKUP="$ROOT/downloads/characters-before-druid-$(date +%Y%m%d-%H%M%S).sql.gz"
echo "backing up the characters database to ${BACKUP#$ROOT/}"
docker compose exec -T database sh -c 'mariadb-dump -umangos -pmangos --single-transaction characters' 2>/dev/null | gzip > "$BACKUP"
[ -s "$BACKUP" ] || { echo "backup is empty, aborting" >&2; rm -f "$BACKUP"; exit 1; }
echo "backup is $(du -h "$BACKUP" | cut -f1)"

docker compose exec -T database sh -c 'mariadb -umangos -pmangos' <<EOF
UPDATE characters.characters
   SET race = $RACE, class = $CLASS,
       reset_talents_multiplier = 0, reset_talents_time = 0
 WHERE guid = $GUID;

-- Talents are stored as spells in vanilla, so this clears the rogue talent
-- tree along with the rogue spellbook.
DELETE FROM characters.character_spell  WHERE guid = $GUID;
DELETE FROM characters.character_action WHERE guid = $GUID;
DELETE FROM characters.character_aura   WHERE guid = $GUID;
DELETE FROM characters.character_stats  WHERE guid = $GUID;

INSERT INTO characters.character_spell (guid, spell, active, disabled)
  SELECT $GUID, Spell, 1, 0 FROM mangos.playercreateinfo_spell
   WHERE race = $RACE AND class = $CLASS;

INSERT INTO characters.character_action (guid, button, action, type)
  SELECT $GUID, button, action, type FROM mangos.playercreateinfo_action
   WHERE race = $RACE AND class = $CLASS;
EOF

echo
echo "now: $(sql "select concat('race ', race, ', class ', class, ', ', (select count(*) from characters.character_spell where guid=$GUID), ' spells, ', (select count(*) from characters.character_action where guid=$GUID), ' action buttons') from characters.characters where guid=$GUID;")"
echo
echo "Log in and finish with GM Box's Tools tab:"
echo "  本职法术 (.learn all_myspells)   -- the rest of the druid spellbook for this level"
echo "  语言     (.learn all_lang)"
echo "  满技能   (.maxskill)"
echo "Rogue-only gear (swords, etc.) stays in the bags but cannot be equipped."
