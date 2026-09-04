# 客户端之上的三层：插件 / DLL mod / 美术补丁

三层互相独立，加载机制、共享方式、失败症状都不一样。**这份文件写的是规则和陷阱**；
某台机器上具体装了哪些插件、哪些 mod，属于那个仓库的 README，不写在这里 —— 两处都
写必然漂移。

| 层 | 加载者 | 能否在多个客户端目录间共享 |
|---|---|---|
| 插件（Lua/XML） | 游戏自身扫 `Interface/AddOns/` | ✅ 符号链接整个目录即可 |
| DLL mod | `dlls.txt` → `libDllLdr.dll` | ❌ **每个客户端目录各一份** |
| 美术补丁 | `WoW.exe` 扫 `Data/patch-?.MPQ` | ❌ 每个客户端目录各一份 |

---

## 一、插件：只有 1.12 时代的能用

**判据是 `.toc` 里的 `## Interface: 11200`。** 为 Classic Era（1.13+）写的插件调用的
API 在 1.12 里根本不存在 —— Questie、DBM、Bagnon、Auctionator、大脚/BigFoot 全是这一类，
勾"载入过期插件"也没用，它们会直接报错或静默失灵。

装之前逐个核对：

```sh
grep -rl "## Interface: 11200" <addons-dir>/*/*.toc     # 能用的
grep -rL "## Interface: 11200" <addons-dir>/*/*.toc     # 需要人工确认的
```

要找 1.12 的对应物，`shagu/*`（pfUI、pfQuest）和各种 backport 仓库是主要来源。

### 几条实践规则

- **整套 UI 替换（pfUI 一类）自带冲突处理**，首次登录会扫描已启用插件并弹框问你关不关。
  功能重复的那些**直接从磁盘删掉**，不要只是关掉 —— 留着每次登录都要被问一遍。
- 冲突表**不是全的**。它认识同作者的插件，不认识第三方的同类件（比如另一个背包插件），
  这种要自己决定留哪个，并在 UI 配置里关掉另一边的对应模块。
- 删插件前打包留底（`tar czf addons-removed-<date>.tar.gz ...`），并把安装脚本里的条目
  **注释掉而不是删掉** —— URL 和 commit 留着，想退回是一条命令的事。
- **新增插件目录要完全重启客户端**才会被识别，`/console reloadui` 不行（它只重跑已加载
  的插件）。改已有插件的文件才是 reloadui 够用的场景。

---

## 二、DLL mod：加载链和它的两个反直觉之处

```
WoW_tweaked.exe
   └─ (PE 导入表，原版就有) DivxDecoder.dll   ← 被 VfPatcher 改过 40 字节，
        └─ LoadLibraryA("libDllLdr.dll")        塞了个 code cave
             └─ 读 <game-dir>/dlls.txt
                  └─ 逐个 LoadLibrary 表里的 DLL
```

**反直觉一：这一层不共享。** 插件靠 `Interface/AddOns` 符号链接两个客户端目录共用，但
`dlls.txt`、`DivxDecoder.dll`、`libDllLdr.dll`、各个 mod DLL、`WoW_tweaked.exe`
**每个客户端目录各有独立一份**。装 DLL mod 必须每个目录都装，只装一边的话另一边悄无
声息地什么都不会发生。两边的 `WoW.exe` 通常逐字节相同，所以 `WoW_tweaked.exe` 可以打
一次直接复制过去。

**反直觉二：补丁烧在 `DivxDecoder.dll` 里，跟用不用 `VanillaFixes.exe` 当启动器无关。**
在 macOS 下直接起 exe（rosettax87 已经处理了 x87/RDTSC，不需要 VanillaFixes 的时序修正），
`VanillaFixes.exe` 本身是死的 —— 但 `dlls.txt` 照样生效。诊断时不要因为"没用 VanillaFixes
启动"就断定 mod 没加载。`DivxDecoder.dll.bak` 是打补丁前的原件。

### 顺序有意义

`dlls.txt` 是按行顺序 `LoadLibrary` 的，有依赖关系的 mod 必须排在被依赖者之后。典型的是
提供 unit GUID / 事件扩展的那类要排在消费它的那类前面。

### 怎么确认某个 DLL 真的加载了

先看它写不写日志（`<game-dir>/Logs/` 下），有日志的直接读；没有日志的进游戏后用它自己
暴露的全局量确认：

```
/run DEFAULT_CHAT_FRAME:AddMessage(SOME_MOD_VERSION or "未加载")
```

### 二进制来源要能追溯

上游仓库消失、换主是常事。选 release 时确认**构建可对照**：由 CI（`github-actions[bot]`）
从某个公开 tag 的 workflow 产出，比手工上传的二进制可信得多。把 URL + tag sha 记进安装
脚本。

---

## 三、美术补丁：`patch-?.MPQ` 是单字符通配槽

1.12 的 `WoW.exe` 里资源补丁槽是 `patch-?.MPQ` —— 单字符通配，所以 `patch-3` 到
`patch-9`、`patch-A` 到 `patch-Z` 全都会被加载，**字符越靠后加载越晚、优先级越高**。
原版只占了 `patch.MPQ` 和 `patch-2.MPQ`，其余全空。

装法就是把 MPQ 丢进 `Data/`，改名到一个空槽。上游常发布成 `patch-3.MPQ`；改名到
`patch-A.MPQ` 可以把数字槽留给别的东西。卸载就是删文件。

### ⚠️ 装之前先核内容，再看它会不会污染服务端数据

用 `mpyq` 之类列出包内文件，**只有 `.blp` / `.m2` 的美术包是安全的**；一旦含 DBC、WMO
或 ADT，就可能和服务端的数据对不上。

更隐蔽的一条：如果客户端目录就是服务端 `storage/mangosd/client-data`（共用一份 MPQ 的
那种布局），那么 `vmapextractor` 会读 `.m2` 做碰撞体。**要重跑 maps/vmaps/mmaps 提取
之前，先把美术补丁挪走**，否则树和建筑的碰撞会跟着模型一起变。

### 国服客户端的额外取舍

中文客户端有和谐化模型。装国际版美术包等于把碰到的那几个模型换回原版形象 —— 这是取舍，
不是 bug。

---

## 四、自制插件的话

1.12 是 **Lua 5.0**，不是 5.1：没有 `#t`（用 `table.getn`）、没有 `%` 运算符（用
`math.mod`）、没有 `...` 变长参数（用 `arg`）、事件处理函数拿的是全局 `this` / `event` /
`arg1` 而不是参数。写完至少过一遍语法检查，`luac -p` 能查语法但查不出这些 API 差异。

顶层 `local` 变量有 200 个的上限，大文件要注意。

要在插件里烤进服务端数据（传送点、物品表之类），从世界库直接导出成 Lua 表比运行时查询
服务端简单得多，也不受协议限制。注意 `item_template` 每件物品**每个补丁各存一行**，
要按 `mangosd.conf` 里的 `WowPatch` 取"不超过该补丁的最新一版"，否则会出现同名重复项。
