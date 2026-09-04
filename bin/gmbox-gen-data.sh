#!/usr/bin/env bash
# Rebuild the GMBox addon's baked-in teleport and item databases from the
# running VMaNGOS world database. Run this after you add teleport points
# (.tele add) or custom items; the addon itself never queries the server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADDON="$ROOT/addons/GMBox"   # shared by both clients via symlink
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$ROOT/vmangos-deploy"

# The world DB holds one item row per content patch; the server uses the
# newest row that is <= WowPatch, so the addon must do the same.
PATCH="$(grep -E '^\s*WowPatch\s*=' config/mangosd.conf | tail -1 | tr -dc '0-9')"
PATCH="${PATCH:-10}"
echo "using WowPatch = $PATCH"

q() { docker compose exec -T database sh -c "mariadb -umangos -pmangos mangos -N --batch -e \"$1\""; }

# name_loc4 is zhCN; empty string when the item has no Chinese name (~11%).
# The trailing columns feed the addon's filters: required_level and item_level
# for the level slider, class/subclass/inventory_type for the armour-type
# check, and the two masks for "can my character actually use this".
q "select t1.entry, t1.quality, t1.name, coalesce(l.name_loc4, ''), \
          t1.required_level, t1.item_level, t1.class, t1.subclass, \
          t1.inventory_type, t1.allowable_class, t1.allowable_race \
   from item_template t1 left join locales_item l on l.entry = t1.entry \
   where t1.patch = (select max(t2.patch) from item_template t2 \
                     where t2.entry = t1.entry and t2.patch <= $PATCH) \
   order by t1.entry;" > "$TMP/items.tsv"

q "select name, map, round(position_x,2), round(position_y,2), round(position_z,2) \
   from game_tele order by name;" > "$TMP/tele.tsv"

python3 "$ROOT/bin/gmbox-gen-data.py" "$TMP" "$ADDON"

