#!/usr/bin/env python3
"""跨阵营：把部落/联盟之间的初始声望从「仇恨 + 开战」改成「中立 + 停战」。

为什么改 Faction.dbc 而不是改 NPC 的 faction：VMaNGOS 的
WorldObject::GetFactionReactionTo() 里，只要 NPC 所属阵营
CanHaveReputation()（reputationListID >= 0），敌对与否就**完全**由玩家对该
阵营的声望等级决定，FactionTemplate.dbc 的 alliance/horde 掩码整段被跳过。
主城 NPC、城卫、任务发布者用的都是这类有声望条的阵营（暴风城 72、铁炉堡 47
……），所以只要把「部落种族对暴风城」的起始声望从 -42000(仇恨) 抬到 0(中立)，
整座城就自动不再动手。

客户端一个字节都不用改：1.12 客户端算名牌颜色用的是服务器下发的
SMSG_INITIALIZE_FACTIONS（standing + flags），不是本地 DBC 的初始值。

character_reputation.standing 存的是**相对 base 的增量**，所以已有角色的
standing=0 会跟着 base 一起变成中立，不需要动。要动的只有存下来的 flags
（见 storage/database/custom-sql/30-cross-faction.sql）。

战场阵营（奥山霜狼/石锤、战歌、阿拉希）故意不碰，否则 BG 会坏掉。
安其拉、木喉、辛迪加、血帆这些「两边都仇视」的中立阵营也不碰。

用法：
    bin/patch-faction-dbc.py            # 打补丁（幂等）
    bin/patch-faction-dbc.py --revert   # 从 .orig 备份恢复
改完必须重启 mangosd，DBC 只在启动时加载一次。
"""
import os, shutil, struct, sys

DBC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "../vmangos-deploy/storage/mangosd/extracted-data/5875/dbc/Faction.dbc")
DBC = os.path.normpath(DBC)
ORIG = DBC + ".orig"

RACE_ALLIANCE = 1 | 4 | 8 | 64    # 人类 矮人 暗夜 侏儒
RACE_HORDE = 2 | 16 | 32 | 128    # 兽人 亡灵 牛头 巨魔

FACTION_FLAG_VISIBLE = 0x01
FACTION_FLAG_AT_WAR = 0x02

# faction id -> (对方阵营的种族掩码, 补丁后的 flags, 名字)
# flags 用 VISIBLE：让四座主城出现在你的声望面板里，可以刷、可以换坐骑，
# 也可以随时手动「宣战」去打联盟 NPC（有部落任务要杀联盟兵时用得上）。
TARGETS = {
    # 联盟四城 —— 部落玩家改成中立
    72:  (RACE_HORDE,    FACTION_FLAG_VISIBLE, "Stormwind"),
    47:  (RACE_HORDE,    FACTION_FLAG_VISIBLE, "Ironforge"),
    69:  (RACE_HORDE,    FACTION_FLAG_VISIBLE, "Darnassus"),
    54:  (RACE_HORDE,    FACTION_FLAG_VISIBLE, "Gnomeregan Exiles"),
    # 部落四城 —— 联盟玩家改成中立（双向，成本一样）
    76:  (RACE_ALLIANCE, FACTION_FLAG_VISIBLE, "Orgrimmar"),
    81:  (RACE_ALLIANCE, FACTION_FLAG_VISIBLE, "Thunder Bluff"),
    530: (RACE_ALLIANCE, FACTION_FLAG_VISIBLE, "Darkspear Trolls"),
    68:  (RACE_ALLIANCE, FACTION_FLAG_VISIBLE, "Undercity"),
    # 外围阵营：辛特兰的野蛮之锤，以及两家阵营限定坐骑训练师
    471: (RACE_HORDE,    FACTION_FLAG_VISIBLE, "Wildhammer Clan"),
    589: (RACE_HORDE,    FACTION_FLAG_VISIBLE, "Wintersaber Trainers"),
    630: (RACE_ALLIANCE, FACTION_FLAG_VISIBLE, "Ravasaur Trainers"),
    # 两个总阵营，本来就是隐藏的，保持隐藏，只去掉开战位
    469: (RACE_HORDE,    None, "Alliance"),
    67:  (RACE_ALLIANCE, None, "Horde"),
}


def load():
    with open(DBC, "rb") as f:
        d = bytearray(f.read())
    magic, rc, fc, rs, _ = struct.unpack("<4sIIII", d[:20])
    if magic != b"WDBC":
        sys.exit(f"{DBC} 不是 DBC 文件")
    if fc != 37:
        sys.exit(f"Faction.dbc 字段数是 {fc}，不是预期的 37，结构对不上，拒绝写入")
    return d, rc, rs


def patch():
    if not os.path.exists(ORIG):
        shutil.copy2(DBC, ORIG)
        print(f"已备份原始 DBC -> {os.path.basename(ORIG)}")
    d, rc, rs = load()
    changed = 0
    for i in range(rc):
        o = 20 + i * rs
        fid = struct.unpack_from("<I", d, o)[0]
        if fid not in TARGETS:
            continue
        opp_races, new_flags, name = TARGETS[fid]
        for slot in range(4):
            race_mask = struct.unpack_from("<I", d, o + 4 * (2 + slot))[0]
            base = struct.unpack_from("<i", d, o + 4 * (10 + slot))[0]
            flags = struct.unpack_from("<I", d, o + 4 * (14 + slot))[0]
            if base >= 0 or not (race_mask & opp_races):
                continue
            want_flags = new_flags if new_flags is not None else flags & ~FACTION_FLAG_AT_WAR
            if base == 0 and flags == want_flags:
                continue
            struct.pack_into("<i", d, o + 4 * (10 + slot), 0)
            struct.pack_into("<I", d, o + 4 * (14 + slot), want_flags)
            print(f"  {fid:<4} {name:<22} slot{slot}: base {base} -> 0, "
                  f"flags 0x{flags:02x} -> 0x{want_flags:02x}")
            changed += 1
    if not changed:
        print("没有需要修改的条目，DBC 已经是打过补丁的状态。")
        return
    with open(DBC, "wb") as f:
        f.write(d)
    print(f"\n改了 {changed} 个声望槽。重启生效： docker compose restart mangosd")


def revert():
    if not os.path.exists(ORIG):
        sys.exit(f"找不到备份 {ORIG}，无法恢复")
    shutil.copy2(ORIG, DBC)
    print(f"已从 {os.path.basename(ORIG)} 恢复。重启生效： docker compose restart mangosd")


if __name__ == "__main__":
    revert() if "--revert" in sys.argv else patch()
