#!/usr/bin/env bash
# 修复 characters 库里 character_inventory <-> item_instance 的不一致。
#
# 症状：角色登录后装备/物品静默消失，Server.log 里出现
#   ERROR: SQL: cannot execute 'INSERT INTO `character_inventory` ...'
#   ERROR: SQL ERROR: Duplicate entry 'NN' for key 'PRIMARY'
#
# 成因：玩家在线时硬重启 mangosd，存档写了一半；之后 ReusableGuidPoolSize
# 让服务器回收 item guid，新物品撞上残留的死行，INSERT 失败 —— 于是又多一条
# 不一致，循环放大。
#
# 本脚本：备份 -> 删孤儿行 -> 关掉 guid 复用 -> 重启 mangosd。
# 所有角色必须离线（脚本会检查）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/vmangos-deploy"

sql() { docker compose exec -T database sh -c "mariadb -umangos -pmangos -N -e \"$1\"" 2>/dev/null | tr -d '\r'; }

ONLINE="$(sql "select ifnull(group_concat(name),'') from characters.characters where online<>0;")"
[ -z "$ONLINE" ] || { echo "还有角色在线：$ONLINE —— 先下线" >&2; exit 1; }

echo "== 修复前 =="
sql "select concat('  孤儿背包行  ', count(*)) from characters.character_inventory ci
       left join characters.item_instance ii on ii.guid=ci.item_guid where ii.guid is null;"
sql "select concat('  无主物品实体 ', count(*)) from characters.item_instance ii
      where not exists(select 1 from characters.character_inventory ci where ci.item_guid=ii.guid)
        and not exists(select 1 from characters.mail_items      m  where m.item_guid=ii.guid)
        and not exists(select 1 from characters.auction         a  where a.item_guid=ii.guid)
        and not exists(select 1 from characters.character_gifts g  where g.item_guid=ii.guid);"

echo "== 停 mangosd =="
docker compose stop mangosd

BACKUP="$ROOT/downloads/characters-before-orphan-repair-$(date +%Y%m%d-%H%M%S).sql.gz"
echo "== 备份 characters 库 -> ${BACKUP#$ROOT/} =="
docker compose exec -T database sh -c 'mariadb-dump -umangos -pmangos --single-transaction characters' 2>/dev/null | gzip > "$BACKUP"
[ -s "$BACKUP" ] || { echo "备份为空，中止" >&2; rm -f "$BACKUP"; docker compose start mangosd; exit 1; }
echo "   备份大小 $(du -h "$BACKUP" | cut -f1)"

echo "== 清理 =="
docker compose exec -T database sh -c 'mariadb -umangos -pmangos' <<'EOF'
USE characters;
-- 1. 指向已不存在实体的背包格子：物品早就没了，只剩死行占着 item_guid 主键,
--    让回收到同一个 guid 的新物品 INSERT 失败。删掉。
DELETE ci FROM characters.character_inventory ci
  LEFT JOIN characters.item_instance ii ON ii.guid = ci.item_guid
 WHERE ii.guid IS NULL;

-- 2. 没有任何格子/邮件/拍卖/礼物引用的物品实体：上一轮 INSERT 失败漏下的,
--    玩家永远拿不到。删掉，免得继续占 guid。
DELETE ii FROM characters.item_instance ii
 WHERE NOT EXISTS(SELECT 1 FROM characters.character_inventory ci WHERE ci.item_guid = ii.guid)
   AND NOT EXISTS(SELECT 1 FROM characters.mail_items      m  WHERE m.item_guid  = ii.guid)
   AND NOT EXISTS(SELECT 1 FROM characters.auction         a  WHERE a.item_guid  = ii.guid)
   AND NOT EXISTS(SELECT 1 FROM characters.character_gifts g  WHERE g.item_guid  = ii.guid);
EOF

echo "== 关掉 item guid 复用 =="
CONF="$ROOT/vmangos-deploy/config/mangosd.conf"
cp "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)"
# compose.yaml 把 mangosd.conf 按「单个文件」挂进容器，`sed -i` 会换 inode,
# 容器里的挂载点就指向被删掉的旧文件了。所以必须原地截断重写，保住 inode。
NEW="$(sed -E 's/^ReusableGuidPoolSize[[:space:]]*=.*/ReusableGuidPoolSize = 0/' "$CONF")"
printf '%s\n' "$NEW" > "$CONF"
grep -n '^ReusableGuidPoolSize' "$CONF"

echo "== 起 mangosd =="
docker compose start mangosd

echo "== 修复后 =="
sql "select concat('  孤儿背包行  ', count(*)) from characters.character_inventory ci
       left join characters.item_instance ii on ii.guid=ci.item_guid where ii.guid is null;"
sql "select concat('  背包行 ', (select count(*) from characters.character_inventory),
                   ' / 物品实体 ', (select count(*) from characters.item_instance));"
