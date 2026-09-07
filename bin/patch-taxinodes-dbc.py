#!/usr/bin/env python3
"""跨阵营：让对方阵营的飞行管理员也认你。

⚠️ **2026-09-07：这个脚本对服务端没有作用，真正生效的是
`storage/database/custom-sql/30-cross-faction.sql` 第 8 段。**

和 `patch-faction-dbc.py` 同一个坑：航点数据也在世界库里（`taxi_nodes` 表，同样带
`build` 列），`ObjectMgr::GetNearestTaxiNode()` 读的是它，不是 `TaxiNodes.dbc`。
脚本保留只为让 DBC 和数据库一致，**光跑它没有任何效果。**

要解决的问题是这个：

    // ObjectMgr::GetNearestTaxiNode()
    if (!node || node->map_id != mapid ||
        !node->MountCreatureID[team == ALLIANCE ? 1 : 0])
        continue;

每个航点有两个 `MountCreatureID` 槽（0 = 部落，1 = 联盟），联盟航点的部落槽是 0。
于是部落角色站在暴风城的狮鹫管理员面前解析不出"当前航点"，`SendTaxiMenu()` 直接
return —— 不是"没有航线"，是飞行地图根本不弹。

所以把只有一边的航点补成两边都有，坐骑按大陆取（东部王国狮鹫 541 / 卡利姆多角鹰兽
3837，部落两边都是双足飞龙 2224）。

**同一个地方有两个航点的不补**（藏宝海湾、加基森、永望镇、月光林地、圣光之愿、
塞纳里奥要塞、瑟银哨塔）。这些地方 Blizzard 本来就是一边一个航点，各自连着自己
阵营的航线网；两个都放开的话 `GetNearestTaxiNode()` 取"最近"会在两个几乎重合的
航点之间乱挑，部落玩家在藏宝海湾可能被解析成联盟那个航点，从藏宝海湾飞格罗姆高
反而会坏掉。

孪生航点是**按名字**认的，不只按距离：暴风城航点（2）旁边 204 码就有一个
`Generic, World target` 的僵尸行（36，部落槽里塞了个 15665），只看距离会把
暴风城当成"部落已经有航点了"而跳过 —— 那可是最该补的一个。

战场地图（30 奥山）不碰，和阵营补丁的取舍一致。

用法：
    bin/patch-taxinodes-dbc.py            # 打补丁（幂等）
    bin/patch-taxinodes-dbc.py --revert   # 从 .orig 备份恢复

注意：航线本身（`TaxiPath`）没动，两个阵营的航线网仍然是分开的。效果是
**走到对方任意一个航点，那整张网就开给你了**，不是从奥格瑞玛直飞暴风城。
"""
import math
import os
import shutil
import struct
import sys

DBC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "../vmangos-deploy/storage/mangosd/extracted-data/5875/dbc/TaxiNodes.dbc")
DBC = os.path.normpath(DBC)
ORIG = DBC + ".orig"

# 1.12 TaxiNodes.dbc, 16 fields:
#   0 id | 1 map | 2-4 x/y/z | 5-12 name[8 locales] | 13 name flags
#   14 MountCreatureID[0] (部落) | 15 MountCreatureID[1] (联盟)
FIELDS = 16
F_MAP, F_NAME, F_HORDE, F_ALLY = 1, 5, 14, 15

MAPS = {0: "Eastern Kingdoms", 1: "Kalimdor"}

# 每个大陆补哪只坐骑：该大陆该阵营已有航点里用得最多的那个。
MOUNT = {
    0: {"horde": 2224, "alliance": 541},    # 双足飞龙 / 狮鹫
    1: {"horde": 2224, "alliance": 3837},   # 双足飞龙 / 角鹰兽
}

# 两个航点挤在一起就算"对方已经有自己的航点了"。实测最近的一对相距 54 码
# （藏宝海湾），最远的一对 181 码（加基森），而真正独立的航点之间远不止这些。
TWIN_RADIUS = 250.0


def load():
    with open(DBC, "rb") as f:
        d = bytearray(f.read())
    magic, rc, fc, rs, _ = struct.unpack("<4sIIII", d[:20])
    if magic != b"WDBC":
        sys.exit(f"{DBC} 不是 DBC 文件")
    if fc != FIELDS:
        sys.exit(f"TaxiNodes.dbc 字段数是 {fc}，不是预期的 {FIELDS}，结构对不上，拒绝写入")
    return d, rc, rs


def read_nodes(d, rc, rs):
    strings = d[20 + rc * rs:]

    def text(off):
        if not off:
            return ""
        return bytes(strings[off:strings.index(b"\0", off)]).decode("utf-8", "replace")

    nodes = []
    for i in range(rc):
        o = 20 + i * rs
        f = struct.unpack_from("<%di" % FIELDS, d, o)
        x, y, _z = struct.unpack_from("<3f", d, o + 8)
        nodes.append({"i": i, "o": o, "id": f[0], "map": f[F_MAP], "x": x, "y": y,
                      "name": text(f[F_NAME]),
                      "horde": f[F_HORDE], "alliance": f[F_ALLY]})
    return nodes


def has_twin(node, nodes, side):
    """同名、同图、近在咫尺、且已经服务 `side` 的另一个航点。"""
    for other in nodes:
        if other is node or other["map"] != node["map"] or not other[side]:
            continue
        if other["name"] != node["name"]:
            continue
        if math.hypot(node["x"] - other["x"], node["y"] - other["y"]) <= TWIN_RADIUS:
            return other
    return None


def patch():
    if not os.path.exists(ORIG):
        shutil.copy2(DBC, ORIG)
        print(f"已备份原始 DBC -> {os.path.basename(ORIG)}")
    d, rc, rs = load()
    nodes = read_nodes(d, rc, rs)

    changed = skipped = 0
    for node in nodes:
        if node["map"] not in MAPS:
            continue
        # 两个槽都空的是运输船/研发用的占位行，两个都满的不用动
        if bool(node["horde"]) == bool(node["alliance"]):
            continue
        side = "horde" if not node["horde"] else "alliance"
        twin = has_twin(node, nodes, side)
        if twin:
            print(f"  跳过 {node['id']:<3} {node['name']:<40} —— {twin['id']} 就在 "
                  f"{math.hypot(node['x'] - twin['x'], node['y'] - twin['y']):.0f} 码外，"
                  f"对方已经有自己的航点")
            skipped += 1
            continue
        mount = MOUNT[node["map"]][side]
        offset = node["o"] + 4 * (F_HORDE if side == "horde" else F_ALLY)
        struct.pack_into("<i", d, offset, mount)
        changed += 1

    if not changed:
        print("没有需要修改的航点，DBC 已经是打过补丁的状态。")
        return
    with open(DBC, "wb") as f:
        f.write(d)
    print(f"\n补了 {changed} 个航点（跳过 {skipped} 个有孪生航点的）。"
          f"重启生效： docker compose restart mangosd")


def revert():
    if not os.path.exists(ORIG):
        sys.exit(f"找不到备份 {ORIG}，无法恢复")
    shutil.copy2(ORIG, DBC)
    print(f"已从 {os.path.basename(ORIG)} 恢复。重启生效： docker compose restart mangosd")


if __name__ == "__main__":
    revert() if "--revert" in sys.argv else patch()
