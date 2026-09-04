# WoW 私服 — Vanilla 1.12.1 (build 5875)

## 组成

| 部分 | 选型 | 位置 |
|---|---|---|
| 客户端 | 原版 Blizzard `WoW.exe`（打过 vanilla-tweaks），跑在 WoWSilicon 的 Wine 上 | `client/`（enUS）、`client-zhCN/`（简中）|
| 服务端 | VMaNGOS（via vmangos-deploy，Docker）| **线上 `$SERVER_HOST:/opt/vmangos`**（在跑的那份）；本地 `vmangos-deploy`（arm64，停着当后备）|
| 客户端资源 | 原版 enUS 1.12.1 的 12 个 MPQ（sha256 全部校验通过）| `vmangos-deploy/storage/mangosd/client-data/Data` |

> AzerothCore 只支持 WotLK 3.3.5a，不支持 1.12 协议，因此 Vanilla 路线改用 VMaNGOS。

> 早期用过 Wowee（原生 macOS/Vulkan 的重实现客户端），**2026-09-03 弃用**——它的
> `classic` profile 有训练师列表字段错位这类编译进 native 代码、Lua 层修不了的缺陷，
> 而原版二进制就是行为的参考实现，这些问题根本不存在。当时的排查记录、本地修复用的
> 两个 addon 和相关脚本打包在 `wowee-removed-20260903.tar.gz`。

## 登录信息

- 认证服务器地址：`server.conf` 里的 `SERVER_HOST`（端口 3724）
- 领域：`VMaNGOS` @ `$SERVER_HOST:8085`
- 账号：自己建，见下面「建号」（`bin/mangos-console.py "account create <名字> <密码>"`）

> ⚠️ **GM 账号直接暴露在公网上，口令要够强。** realmd 有
> `WrongPass.MaxAttempts = 10` / `ThrottleWindowDurationSec = 60` 的限流，
> 但扛不住有针对性的爆破。改密码（走 mangosd 控制台，密码要打两遍）：
>
> ```sh
> ssh "$SERVER_SSH_USER@$SERVER_HOST" -t 'docker attach vmangos-mangosd-1'
> # 提示符出来后输：
> #   account set password <账号> <新密码> <新密码>
> # 然后 Ctrl-P Ctrl-Q 脱离——不要 Ctrl-C，那会把 mangosd 一起停掉
> ```
>
> 改完记得 `SERVER_HOST=$SERVER_HOST bin/auth-check.py <账号> <新密码>` 验一下。

## 线上部署（2026-09-03）

服务端搬到了一台 VPS（Ubuntu 24.04 / x86_64 / 4 核 / 3.8G 内存），
目录 `/opt/vmangos`，和本地 `vmangos-deploy` 同一套 compose，只有
`VMANGOS_REALMLIST_ADDRESS` 从 `127.0.0.1` 改成了那台机器的公网地址
（这个值由 database 容器写进 `realmd.realmlist` 表，客户端选完领域后
按它去连世界服务器——填错的话能登录但进不去游戏）。

搬过去的东西：

| 内容 | 大小 | 方式 |
|---|---|---|
| `storage/mangosd/extracted-data`（maps/vmaps/mmaps/dbc）| 2.7G / 10716 个文件 | rsync |
| `config/mangosd.conf`、`config/realmd.conf` | — | scp，逐字节相同 |
| `storage/database/custom-sql/*.sql` | 3 个 | scp |
| MariaDB 数据目录（账号、角色、world 库）| 59M（打包后）| 停库 → tar volume → 解到远程 volume |

数据库是整个数据目录搬的，不是 mysqldump，所以账号（含 `account_access`
里的 GM 6）、两个角色（Alice 18、Flora 16）、migration 状态全都是原样。
远程首次启动时镜像检测到一条新的 migration edit，按 `VMANGOS_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS=1`
自动重建了 world 库并重跑了那三个 custom SQL——characters / realmd 库不受影响。

主机上还跑着另一个项目（rewindom，占 80/443/3700），3724 和 8085 都是空的，
无防火墙拦截。原本没有 swap，加了 4G（`/swapfile`，已写进 `/etc/fstab`）。
实际占用很省：mangosd 280M、realmd 30M、database 155M——mmaps 是按需 mmap 的，
不会一次全进内存。

### 管服务器

```sh
ssh "$SERVER_SSH_USER@$SERVER_HOST"
cd /opt/vmangos
docker compose ps
docker compose logs -f mangosd
docker compose restart mangosd
```

公钥已经放进 `/root/.ssh/authorized_keys`，但这台机器 sshd 全局
`PubkeyAuthentication no`，所以现在还是走密码。要免密：

```sh
ssh "$SERVER_SSH_USER@$SERVER_HOST" \
  "sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
   && sshd -t && systemctl reload ssh"
```

### 本地那份

`vmangos-deploy` 已经 `docker compose stop`，数据原样留着当后备。
**别两边同时开**——角色数据会各走各的，之后合不回去。真要回本地：
`bin/set-realmlist.sh local` + 本地 `docker compose up -d`，但线上练的进度不会跟回来。

`client/` 那个符号链接指向本地的 `storage/mangosd/client-data`，客户端 MPQ 还在本地，
和服务端搬没搬没关系。

## 日常操作

服务端在线上，平时不用管它（`restart: unless-stopped`，机器重启会自己起来）。
要看状态或重启见上面「管服务器」。

启动客户端：双击 **WoW.app**（在面板里选语言/画面/服务器），或 `bin/play-wine.sh [客户端目录]`

## 脚本

| 脚本 | 用途 |
|---|---|
| `bin/01-unpack-client.sh` | 解压客户端 zip 到 client-data |
| `bin/02a-extract-maps-vmaps.sh` | 提取 maps / vmaps / dbc（几分钟）|
| `bin/02b-extract-mmaps.sh` | 提取 mmaps 寻路网格（数小时）|
| `bin/mangos-console.py` | 向 mangosd 控制台发命令（pty attach，安全脱离）|
| `bin/auth-check.py` | 独立 SRP6 客户端，端到端验证认证链路（`SERVER_HOST=$SERVER_HOST` 验线上）|
| `bin/set-realmlist.sh` | 切两个客户端连的服务器：`online` / `local` / 任意地址 |
| `bin/gmbox-gen-data.sh` | 重新生成 GM Box 插件的传送点/物品数据表 |
| `bin/play-wine.sh` | 用 WoWSilicon 的 Wine 启动指定客户端目录 |
| `bin/install-addons.sh` | 安装/更新那套 1.12 插件（支持 `LOCALE=` / `DEST=`）|
| `launcher/build.sh` | 把 `launcher/*.swift` 编译成 `WoW.app`（改了启动器要重跑）|
| `launcher/make-signing-identity.sh` | 造本机自签的代码签名身份,让辅助功能授权不被重新编译冲掉（跑一次）|

## 客户端

| 目录 | 语言 | 命令行启动 |
|---|---|---|
| `client/` | enUS | `bin/play-wine.sh` |
| `client-zhCN/` | 简体中文 | `bin/play-wine.sh client-zhCN` |

### 启动器：WoW.app

`WoW.app` 是两个客户端共用的入口（原来的 WoW EN.app / WoW CN.app 已合并进它），
拖进 Dock 或 Finder 侧边栏即可。双击弹出面板，六个分页，底栏一行摘要 + 服务器延迟 + 开始游戏：

| 页 | 项 | 落到哪儿 |
|---|---|---|
| **常规** | 语言 | 决定启动哪个客户端目录，并写 `Config.wtf` 的 `SET locale` |
| | 服务器 | 线上 / 本地 / 自定义 —— 同时写 `realmlist.wtf` 和 `Config.wtf` 的 `SET realmList` |
| | 下次直接进游戏 | 存进 `launcher.json`，见下 |
| **画面** | 模式 | 全屏 / 窗口 / 独占全屏。「全屏」在有辅助功能授权时走 macOS 原生全屏(独占一个 Space);没授权时退化成无边框满屏 |
| | 显示器 | 让游戏开在哪块屏。默认「跟着这个面板走」——把面板拖到哪块屏，游戏就开在哪块。见下面「跑在副屏上」 |
| | 分辨率 | `gxResolution`；「跟随显示器」按目标屏的桌面尺寸算 |
| | 帧率上限 | `dxvk.conf` 的 `d3d9.maxFrameRate`（不是游戏 cvar）|
| | UI 缩放 | `uiScale` |
| **声音** | 四条音量 | `MasterVolume` / `MusicVolume` / `SoundVolume` / `AmbienceVolume` |
| **高级** | 画质 | 低/中/高/极限一次刷十几个视距、阴影、各向异性 cvar；默认**保持不变**，不碰手调过的值 |
| | Wine Retina 模式 | prefix 注册表的 `Mac Driver\RetinaMode` |
| | 原生全屏 | 辅助功能授权状态,没授权时这里能一键去授权 |
| **同步** | 角色数 | 两端各有几个角色，`bin/sync-characters.sh status` 现读 |
| | 线上 → 本地 / 本地 → 线上 | 整库同步；默认先备份目标端，备份落在 `downloads/db-sync/` |
| **文件** | 日志 / 客户端 / 插件 / WTF / 截图 | 一键在 Finder 里打开 |

选择存在 `launcher.json`。勾上「下次直接进游戏」以后双击就直接起飞，**按住 ⌥ 双击**才回到面板。

几条硬规矩：

- **不要开独占全屏**（`gxWindow 0`）。Wine 下切回桌面时模式切换会挂死，这是这个客户端唯一
  一个稳定复现的死法，游戏里的 Alt+Enter 同理别按。无边框满屏看着一样，Cmd-Tab 还是稳的。
  面板里那一项留着是为了完整，选中会有橙字警告。
- **游戏开着的时候面板不给启动**，会弹框拦下来。客户端退出时把 `Config.wtf` 整个写回去，
  这时候改什么都会被它覆盖 —— 同样的道理见 `bin/set-realmlist.sh`。
- 面板打开时 UI 缩放和音量是从当前客户端的 `Config.wtf` **现读**的，不是从 `launcher.json`
  读的。所以你在游戏里调过的值，下次开面板看到的就是新值，不会被打回去。

启动器本身只是把配置写好，然后 `exec bin/play-wine.sh`，并且带 `WINDOWED=0` 让脚本
别再插手那两个窗口 cvar。输出照旧在 `/tmp/wow-client.log` 和 `/tmp/wow-client-zhCN.log`。

#### 跑在副屏上 / 让游戏独占一个桌面

**1.12 的客户端没法被告知用哪块屏。** 完整的 cvar 表里只有 `gxWindow`、`gxMaximize`、
`gxResolution`,没有 `gxMonitor`:

```sh
strings -a client-zhCN/WoW_tweaked.exe | grep -oE '^gx[A-Za-z]+$' | sort -u
```

它调 `MonitorFromRect`,也就是**窗口落在哪块屏,就在哪块屏最大化**;而 Wine 把窗口摆在
桌面原点,原点永远是主显示器。所以这件事只能在 macOS 那一侧解。启动器里有两条路,
`Launcher.plan(_:)` 决定走哪条。

**① 有辅助功能授权 → 辅助功能 API + 原生全屏(默认走这条)**

客户端开出来的是个普通 Cocoa 窗口,`AXPosition` 能挪、`AXFullScreen` 能全屏,而 macOS 的
原生全屏本来就会**自动给这个窗口开一个专属 Space** —— 「新建一个桌面」这件事等于白拿。

所以「无边框满屏」这一项在这条路上写的是**窗口** cvar(`gxWindow 1` + `gxMaximize 0`),
尺寸写成目标屏的完整桌面尺寸,起飞后再交给 macOS 变全屏。之所以必须窗口模式:Wine 的
`adjustFullScreenBehavior:` 明确排除 maximized 的窗口,`gxMaximize 1` 根本拿不到全屏按钮。
尺寸提前写准是为了进全屏时内容区尺寸不变,客户端不用重建交换链,也就不会被 DXVK 拉伸糊掉。

找窗口的判据是**全屏按钮**而不是标题或尺寸 —— wine 同时开着好几个窗口(菜单栏那条
1920x30、几个隐藏的),只有真正的游戏窗口有 `kAXFullScreenButtonAttribute`。

这条路显示器排列一点都不碰,菜单栏和 Dock 不搬家,游戏自带一个 Space,三指滑就能切进切出。
启动器等窗口出来、挪好、全屏,然后自己退掉。

> **授权一次就够了。** 早先 `WoW.app` 是 ad-hoc 签名,TCC 记的指定要求是一串 cdhash,
> 二进制一变就失效,每改一次启动器都得重新授权 —— 而且**系统设置里那个开关看着还是开的**,
> 看起来一切正常功能就是不灵。现在 `build.sh` 改用本机自签证书签名
> (`launcher/make-signing-identity.sh` 造一次,不需要 sudo),指定要求只跟证书绑定,
> 重新编译不掉。「高级」页那一行显示当前状态。

**② 没有授权 → 临时把目标屏设成主显示器(兜底)**

`CGConfigureDisplayOrigin` 把目标屏的原点挪到 `(0,0)` 它就是主屏,公开 API,不需要任何权限。
游戏退出后摆回去。排列在动手之前先写进 `launcher-display-restore.json`,启动器被强杀的话
下次开面板会自动摆回来;用的是 `kCGConfigureForSession`,注销一次也会复原。

代价是**玩的时候菜单栏和 Dock 会跟着搬到那块屏**,而且启动器不能 `execv` 掉自己 ——
总要有人活着等游戏退出,所以它收起面板、切成 accessory(从 Dock 消失),在后台线程上守着。

**「显示器」那一项**默认是「跟着这个面板走」,取面板窗口所在的屏(`NSWindow.screen`)——
想在哪块屏玩,把面板拖过去再点开始游戏。勾了「下次直接进游戏」时没有窗口,退而求其次用
鼠标所在的屏。单屏时它和「当前主显示器」完全等价。

**试过但走不通的两条**:Wine 虚拟桌面(`explorer /desktop=`)—— WoWSilicon 这个 Wine 里
`explorer.exe` 自己就崩(SEH 异常);自己调私有 API 建 Space(`CGSSpaceCreate` 那套)——
必须从 Dock 进程里调,要求关掉 SIP。

纯手工也随时能用:游戏窗口是 layer 0 的普通层级窗口,按 F3 打开调度中心拖到别的桌面,
或者 Dock 图标右键 → 选项 → 指定给。

#### 改启动器

`launcher/build.sh` 重新编译（要 Xcode 的 swiftc，会自动收 `launcher/*.swift`），
产物直接覆盖 `WoW.app`。源码分五块：`Model.swift`（设置与 Config.wtf 读写）、
`Displays.swift`（显示器枚举与排列切换）、`Native.swift`（辅助功能 API 挪窗口 + 原生全屏）、
`Launch.swift`（`LaunchPlan` 与起飞的三条路）、`ContentView.swift` + `main.swift`（面板与入口）。

**为什么是分页而不是折叠区**：`Form` 的 `.grouped` 样式自带一个 `ScrollView`，内容一多
就冒滚动条，折叠区展开的瞬间尤其难看。现在五页各自高度写死（`ContentView.pageHeight`），
用 `Form` 的默认样式（只对齐标签列、不滚动），窗口尺寸自始至终不变，结构上就没有可滚的东西。
代价是往页里加控件得重新量一次高度：

```sh
WOW_MEASURE=video WoW.app/Contents/MacOS/WoWLauncher   # general|video|audio|advanced|folders
```

只画那一页、去掉高度约束，窗口高度减 32（标题栏）就是它的自然高度，五页取最大的填回
`pageHeight`。同理，选项的出现/消失会改高度，所以自定义地址框是常驻变灰的，显示模式那句
说明用 `lineLimit(2, reservesSpace: true)` 占死两行。

#### 看不见界面的时候怎么验界面

这台机器没给终端屏幕录制权限,`screencapture` 拿不到窗口图像。两条替代路子,都不需要那个权限:

**量布局用辅助功能 API。** `AXUIElementCreateApplication(pid)` 把每个控件的 role、坐标、
尺寸、文本读成数字 —— 标签列有没有对齐、说明折在第几个字、卡片是不是等高,比肉眼准。
本仓库的分页布局(标签列 62pt、控件从同一条竖线起、卡片精确等高 58)全是这么调出来的。

**看渲染让 app 自己截自己。** 进程内 `cacheDisplay` / `CALayer.render` **不走屏幕录制权限**。
`launcher/main.swift` 里埋了个钩子:

```sh
WOW_SNAPSHOT=/tmp/panel.png WoW.app/Contents/MacOS/WoWLauncher &
kill -USR1 <pid>     # 视图 cacheDisplay -> /tmp/panel.png
kill -USR2 <pid>     # 层树 CALayer.render -> /tmp/panel.png.layer.png
```

用信号而不是定时器,是为了能抓「鼠标正按着」那一帧:外面先用 `CGEvent` 把鼠标按下去
(需要辅助功能授权,已经有了),再发信号。两种抓法都留着 —— 结论一致才可信。

#### 滑杆是自己画的

`launcher/Slider.swift` 的 `KnobSlider`。**这个 macOS 上,滑块被按住时圆钮整个不画**,
只剩一条轨道,看着像「透底」。用上面那套抓帧做的对照实验:

| 写法 | 按住时圆钮 |
|---|---|
| 最朴素的 `Slider` | **消失** |
| AppKit 原生 `NSSlider` | **消失** |
| 加不透明背景 / `compositingGroup()` / 换 `controlSize` | 正常(没按而已)|

按最右端和按中间一样,不是被裁掉;`cacheDisplay` 和 `CALayer.render` 两种抓法结论一致。
既然 `NSSlider` 也中招,应用侧换控件实现就没有出路了,只能自己画。

尺寸和配色是从系统滑杆的截图上**逐像素量的**(深色模式 2x):轨道高 6pt;已填充
`#257DFA`(就是 accent);未填充 `#343434`(底色 `#1E1E1E`,约 `primary.opacity(0.12)`);
圆钮 **19×16pt 胶囊**(不是正圆)、`#DDDDDD`、下方约 4pt 很淡的阴影。浅色模式下系统圆钮
是白的,所以按 `colorScheme` 换。

`WOW_MEASURE=slidertest` 是留着的对照页:系统滑杆和自绘滑杆并排,随时能再验一次。

**图标**由 `launcher/make-icon.swift` 生成，源图是 `launcher/emblem.png`（那枚圆徽章，
四角透明）。它把徽章摆到一块 Apple 标准比例的 squircle 底板上（1024 画布 / 824 底板 /
185.4 圆角），再按整套尺寸阶梯逐个渲染 —— 底板和金边是矢量的，小图不是大图缩出来的。
原来那份 `.icns` 只有一张 256x256 的满幅方图，Retina 下糊，形状也跟别的 Dock 图标不是一套。
`make-icon.swift` 或 `emblem.png` 一改，`build.sh` 会自动重新生成。

两份是同一个游戏、同一个二进制（`WoW.exe` 逐字节相同），只有 `Data/` 的 MPQ 不同。
中文那份的说明见 `client-zhCN/README.md`。

**插件是共享的**：两边的 `Interface/AddOns` 都是指向 `addons/` 的符号链接，
装一次两个客户端都有，也不会各自漂移。可行是因为 Blizzard 的存根（`Blizzard_*/*.pub`）
两边 `diff -rq` 完全相同，而 pfQuest 的中文版同时带 `db/enUS` 和 `db/zhCN`、运行时按
`GetLocale()` 选，所以一份装两处都对。

**不能共享的**：`Data/` 的 MPQ 每一个尺寸都不同（连 model/texture 都不一样——国服有和谐
化模型），`WTF/` 里 `SET locale` 不同、账号状态也各自独立。

语言不能在游戏里切——vanilla 启动时由 `Config.wtf` 的 `SET locale` 决定，换语言就是
换目录启动。服务端会跟着客户端上报的语言自动发中文任务/物品/NPC 文本。

### 画质补丁：patch-A.MPQ（Improved Models）

1.12 的 `WoW.exe` 里资源补丁槽是 `patch-?.MPQ`——单字符通配，所以 `patch-3` 到
`patch-9`、`patch-A` 到 `patch-Z` 全都会被加载，字符越靠后加载越晚、优先级越高。
原版只占了 `patch.MPQ` 和 `patch-2.MPQ`，其余全空。

已装 [Koward/Improved_Models](https://github.com/Koward/Improved_Models) v2.1
（上游发布时叫 `patch-3.MPQ`，这里改名放进 `patch-A.MPQ`，把数字槽留给别的东西）：

```
url     https://github.com/Koward/Improved_Models/releases/download/v2.1/imp_standard.zip
sha256  32e4b2882d298b0ed6dcf9519a6ded449c260c55f66580a07921495f2e8031bf  (zip)
        360e62ebd0a834a2d7b430a6b7de119975458a1cb137d6d623359b886b78b921  (MPQ)
装在    client/Data/patch-A.MPQ 和 client-zhCN/Data/patch-A.MPQ
```

内容用 mpyq 逐条核过：**254 个文件，只有 198 个 .blp 和 56 个 .m2**，
没有 DBC、没有 WMO、没有 ADT——也就是说不可能和服务端的数据对不上。改的是
德鲁伊变形（熊/豹）、狼、猛禽、螃蟹、鳄鱼、蝙蝠、雪人这些生物模型，暴风城的喷泉
和店铺招牌、艾尔文和荆棘谷的树、副本贴图，外加几个界面按钮。

卸载就是 `rm client/Data/patch-A.MPQ client-zhCN/Data/patch-A.MPQ`。

两个注意点：

- `client/` 是指向 `vmangos-deploy/storage/mangosd/client-data` 的符号链接，也就是
  服务端提取 maps/vmaps/mmaps 时读的那份 `Data/`。这个补丁里有 `.m2`，`vmapextractor`
  会读 m2 做碰撞体。**要重跑 `bin/02a-*` / `02b-*` 之前先把 `patch-A.MPQ` 挪走**，
  免得树和招牌的碰撞跟着变（影响极小，但没必要引入差异）。
- 国服客户端有和谐化模型，这个包是国际版模型，装上去等于把碰到的那几个（雪人、
  恐惧魔王、troll 之类）换回原版形象。想要哪种自己取舍。

## 客户端 mod（DLL 层）

这一层很不直观，先说清楚加载链是怎么走的：

```
WoW_tweaked.exe
   └─ (PE 导入表，原版就有) DivxDecoder.dll   ← 被 VfPatcher 改过 40 字节，
        └─ LoadLibraryA("libDllLdr.dll")        塞了个 code cave
             └─ 读 client/dlls.txt
                  └─ 逐个 LoadLibrary 表里的 DLL
```

**关键点一：这一层不是共享的。** 插件靠 `Interface/AddOns` 符号链接两个客户端共用，
但 `dlls.txt`、`DivxDecoder.dll`、`libDllLdr.dll`、各个 mod DLL、`WoW_tweaked.exe`
**每个客户端目录各有独立一份**。装 DLL mod 必须 `client/` 和 `client-zhCN/` 两边都装，
只装一边的话另一边悄无声息地什么都不会发生。两边的 `WoW.exe` 逐字节相同，所以
`WoW_tweaked.exe` 可以打一次直接复制过去。

**关键点二：补丁烧在 `DivxDecoder.dll` 里，跟用不用 `VanillaFixes.exe` 当启动器无关。**
macOS 下 `bin/play-wine.sh` 是直接起 exe 的（rosettax87 已经处理了 x87/RDTSC，不需要
VanillaFixes 的时序修正），所以 `VanillaFixes.exe` 本身是死的——但 `dlls.txt` 照样生效。
`DivxDecoder.dll.bak` 是打补丁前的原件。

`client/dlls.txt` 当前内容：

| DLL | 作用 |
|---|---|
| `wow_turbo.dll` | 性能 |
| `mods/winerosetta.dll` | Wine 桥接，Apple Silicon 上跑起来的前提 |
| `mods/libSiliconPatch.dll` | Apple Silicon 指令优化 |
| `SuperWoWhook.dll` | SuperWoW 2.2：真实 unit GUID、`SpellInfo()`、`UNIT_CASTEVENT` |
| `nampower.dll` | nampower 4.6.1：法术排队 |

顺序有意义，SuperWoW 要在 nampower 前面。

**SuperWoW** — pfUI 自带整套兼容层（`modules/superwow.lua`），装上才不是死代码。单人向的
实际收益是**所有单位都有施法条**，不只是当前目标：打怪时能看见对方在读什么，好打断、好躲。
不需要 `SuperWoWlauncher.exe`，走 `dlls.txt` 就行。

**nampower** — 修 1.12 的施法排队，消掉"法术还没准备好"的空转，手感提升最直接。
注意两条：① 它和 pfUI 的 mouseover 宏有已知时序 bug，**只有装了 SuperWoW 才修好**，
所以这两个是配套的；② 上游 `gitea.com/avitasia/nampower` 已经消失，现用的是
`brues-code/nampower` v4.6.1——该 release 由 `github-actions[bot]` 从 tag sha `2c7f51c`
的 CMake workflow 构建上传，源码公开可对照，不是手工传的二进制。

配置：全部通过 CVar，`/run SetCVar("NP_SpellQueueWindowMs","1000")`，或直接写进
`WTF/Config.wtf`。启动后 `client/Logs/nampower_debug.log` 会列出所有生效的 CVar，
这也是验证它加载成功最快的办法。SuperWoW 没有日志，进游戏后用
`/run DEFAULT_CHAT_FRAME:AddMessage(SUPERWOW_VERSION or "未加载")` 确认。

### 关于"公平性"这条自律条款

`dlls.txt` 里原本有一条规矩：只收性能和 bugfix，不要任何改变战斗时序、距离、目标选择
或信息量的东西。**2026-09-03 有意废除**——这是本地单机服，账号是 ADMIN，装着 GMBox
可以随时传送和刷任何东西，不存在需要对谁公平。判断标准换成了：solo 玩着爽不爽。

### vanilla-tweaks

`client/vanilla-tweaks.exe`（brndd，v1.6.0）把补丁打进 exe，产出 `WoW_tweaked.exe`，
和上面的 DLL 层是两回事。当前是**默认全开 + 手动开了 max camera distance**：

```sh
cd client && wine vanilla-tweaks.exe --maxcameradistance 100 WoW.exe
```

默认开的九项：宽屏 FoV 修正、后台出声、声道数 12→64、farclip 上限、草地距离、
快速拾取（按 shift 手动拾取）、姓名板距离 20→41 码、Large Address Aware、镜头跳转 bug 修复。
只有 max camera distance 默认不开，所以要显式给参数。打完用
`/console CameraDistanceMax 100` 才真正拉远。

改完 exe 记得 `WoW.exe` 本身没动，随时可以重打。

## 插件

装在 `client/Interface/AddOns/`。**只有为 1.12 写的插件能用**——Questie、DBM、Bagnon、
Auctionator、大脚/BigFoot 这些是 Classic Era（1.13+）的，调用的 API 在 1.12 里根本不存在，
勾"载入过期插件"也没用。下表是逐个核对过 `## Interface: 11200` 的一套。

因为是单机本地服，团队向的东西一律不装：仇恨表、稀有怪扫描（unitscan）都没有意义
——想要什么直接用 GM 命令刷或者传过去。**2026-09-03 又按玩法（旅行、观光、做任务，
外加偶尔刷本）砍了一轮数值向的件**，见下面「按玩法裁掉的」。

| 插件 | 打开 | 作用 | 来源 |
|---|---|---|---|
| **pfQuest** 7.0.1 | `/db` | 任务指引 + NPC/物品/物件数据库，地图和小地图标点。1.12 的事实标准，Questie 的位置 | `shagu/pfQuest` |
| **Bagshui** 1.0.5 | `/bs` | 合并背包 + 自动分类，Bagnon 的位置 | `absir/Bagshui`（镜像，作者 veechs）|
| **Atlas / AtlasLoot / AtlasQuest** | `/atlas` `/al` | 副本地图、Boss 掉落表、副本任务 | `Cabro/Atlas`（1.12 backport）|
| **SuperMacro** | `/smacro` | 突破宏长度限制、宏库、`/run` 辅助 | `Monteo/SuperMacro` |
| **GM Box** | `/gm` `/gt` `/gi` | 自制 GM 面板，见 `client/Interface/AddOns/GMBox/README.md` | 本仓库 |
| **CleverMacro** | 宏编辑器 | 给 1.12 补条件宏（`[mod:alt]` `[harm]` `[stance]`），和 SuperMacro 互补不冲突 | `DanielAdolfsson/CleverMacro` |

### pfUI —— 整套 UI 替换

`shagu/pfUI` 是 1.12 的整套界面替换（头像框、动作条、背包、聊天、姓名板、小地图），
vanilla 时代 ElvUI 的位置，和上面那些出自同一个作者。已装，pin 在 `b2f6df8`。

它自带冲突处理（`modules/addoncompat.lua`）：首次登录扫描已启用的插件，发现功能
重复的就弹框问你要不要关，选择记在 `pfUI_init.addons` 里不会重复问。它的软冲突表里
点了这几个的名：

    ShaguPlates  ShaguTweaks  ShaguBoP  ShaguError  ShaguMount  ShaguValue

**2026-09-03 这七个（含 ShaguTweaks-extras）已经从磁盘删除**，不是关掉——功能 pfUI
全都有（`nameplates` / `sellvalue` / `autoshift` / `loot` / 错误屏蔽），留着只会让 pfUI
每次登录都来问一遍。ShaguPlates 尤其没有留的道理，它本来就是 pfUI 姓名板模块导出的
独立版，两个一起开会抢同一批框体。

`bin/install-addons.sh` 里这七条改成了注释，URL 和 commit 都还在。真想退回默认 UI，
把注释里的条目恢复、再关掉 pfUI 即可；备份也在 `addons-removed-20260903-083503.tar.gz`（按玩法裁掉的那批
在 `addons-removed-20260903-102345.tar.gz`）。

**pfUI 不认识 Bagshui**（不在它的冲突表里），所以两个背包插件默认会同时开。
**Flora 上已经处理过了**：`pfUI_config.disabled.bags = "1"`，pfUI 的背包模块关掉，
背包归 Bagshui 管（要它的自动分类）。新角色第一次登录得自己在 `/pfui` 里勾一次
`Disable Module bags`，或者反过来在角色界面关掉 Bagshui 用 pfUI 自带的背包。

### 在 pfUI 之上还有用的小件

这些不在 pfUI 的冲突表里，是纯增量：

| 插件 | 作用 |
|---|---|
| **ShaguNotify** | 成就式弹窗：升级、学会新技能、拿到好东西。vanilla 没有成就系统，这个补那股仪式感 |
| **ShaguKill** | 还差几只怪升级 |
| **pfQuest-icons** | pfQuest 的采集点换成 Gatherer 图标 |

### 按玩法裁掉的

玩法是**旅行、观光、做任务，外加偶尔刷本**，所以 2026-09-03 把只在"看数字"时才有用
的那半边拆了。都是注释掉不是删条目，`bin/install-addons.sh` 里 URL 和 commit 都还在，
文件夹备份在 `addons-removed-20260903-102345.tar.gz`。

| 拿掉 | 为什么 | 装回 |
|---|---|---|
| **ShaguDPS** | 伤害统计。solo 打怪没人跟你比 | 刷本想看输出就装回来 |
| **ShaguScore** | 装等评分。GMBox 能直接刷任何装备，评分没有意义 | |
| **ShaguInventory** | 跨角色持有数量。在玩的只有一个号 | |
| **BetterCharacterStats** | 法伤/命中/暴击面板。观光路上不看这些 | 认真配装时装回来 |
| **ItemRack** | 装备套装切换。一套穿到底 | |
| **ATSW** | 制造队列。采集不需要制造窗口 | 认真做专业时装回来 |
| **pfStudio** | 游戏内 Lua IDE。开发工具，不是游戏插件 | 改 GMBox 时装回来 |

```sh
bin/install-addons.sh ShaguDPS        # 单独装回某一个
```

**Atlas 三件套（Atlas + AtlasLoot + AtlasQuest）留着**——副本还是要刷的，地图、Boss
掉落表、副本任务三样都还在用。真正砍掉的只有团队规模和纯数值的东西。

### pfUI 的"旅行"预设

`bin/pfui-travel-preset.py` 把一套偏观光的设定盖到 pfUI 配置上。pfUI 的
`pfUI_config` 是**按角色存**的（`WTF/Account/<账号>/<realm>/<角色>/SavedVariables/pfUI.lua`），
所以每个角色都得盖一次；不给参数就是全客户端全角色都盖。

```sh
bin/pfui-travel-preset.py --dry-run    # 先看会改什么
bin/pfui-travel-preset.py              # 真改，原文件留一份 .pre-travel-preset
```

**客户端必须先完全退出。** WoW 退出登录时会整份重写 SavedVariables，游戏开着改等于白改。

改的 15 项：

| 项 | 改成 | 为什么 |
|---|---|---|
| `worldmap.mapreveal` + `mapexploration` | 开 | **最值的一条**：世界地图把没去过的区域地形也画出来，还标出探索点。地图从一片黑变成可以拿来计划下一趟走哪 |
| `minimap.size` | 140 → 170 | 客户端跑在 2560x1440，140 太小 |
| `minimap.zonetext` / `coordstext` | 常驻 | 区域名和坐标一直挂着，不用鼠标悬停；配合 pfQuest 找点 |
| `questlog.showQuestLevels` | 开 | 任务列表显示等级 |
| `panel.left.right` | friends → bagspace | 单机服没有好友列表可看，换成背包剩余格子 |
| `screenshot.levelup` / `loot` / `caption` / `hideui` | 开 / 紫装 / 开 / 开 | **旅行日志**：升级和吃到紫装时 pfUI 自动截图，截之前把整个 UI 藏掉，照片上打时间戳和「大区 - 小区」。见 `pfUI/modules/screenshot.lua` |
| `disabled.raid` | 关模块 | solo 不开团。5 人本走的是 `group` 模块，不受影响 |
| `disabled.targettargettarget` | 关模块 | 目标的目标的目标，团本解析用的 |
| `disabled.updatenotify` | 关模块 | 离线服，不用查 pfUI 更新 |
| `border.shadow` | 开 | 边框加投影，边界更清楚 |

动作条**一个都没动**。查过服务器 `character_action` 表：Flora 在 bar1/3/4/5/6 上一共
放了 31 个按钮，Alice 29 个——那几条条不是摆设，关掉会让按钮点不到。想少几条条得先
自己把技能挪一挪，挪完再 `/pfui` 里关。

顺手值得知道的两个：

- **`/farm`** —— pfUI 的采集模式。小地图铺开放大、其余 UI 全隐藏，pfQuest 的采集点直接
  画在上面。赶路和找草药矿点时按一下，再按一下回来。
- **Alt+Z** —— vanilla 原生的隐藏全部 UI，纯手动截图用。

### 观光取向的画面参数

这些是 CVar 不是 UI，但对"看风景"影响比任何插件都大。**在游戏里用 `/console` 调**，
别直接改 `Config.wtf`——客户端退出时会把内存里的值整份写回去，覆盖手改的内容。

```
/console farclip 777            # 视距，当前 477。vanilla-tweaks 已经解掉了上限
/console frillDensity 128       # 地面草的密度，当前 24
/console groundEffectDist 200   # 草的绘制距离，当前 100
/console doodadAnim 1           # 场景物件动画（旗帜、树叶、水车），当前关
/console shadowlod 1            # 阴影，当前 0
```

前三条吃帧数，一条一条加、看着帧数调。`cameraDistanceMax 100` 和
`cameraDistanceMaxFactor 5` 已经在 `Config.wtf` 里了（靠 vanilla-tweaks 解锁，见上面
那节），镜头能拉得很远，观光就靠这个。

重装或换新客户端时：

```sh
bin/install-addons.sh            # 全部
bin/install-addons.sh pfQuest    # 只装某几个
```

脚本把每个来源钉在验证过的 commit/tag 上，装完会打印各自的 `## Interface` 行；
它还会去掉 TOC 开头的 UTF-8 BOM（AtlasLoot 就带 BOM，不去掉的话 1.12 读不到
`## Interface` 行，插件会被当成过期件禁用）。

### Script Memory 必须设为 0

1.12 客户端默认给插件 Lua 的内存上限是 **48 MB**，pfQuest 一个就吃得差不多，超了会弹
"The user interface is using more than 48MB of memory"。已在 `client/WTF/Config.wtf` 里写入：

```
SET scriptMemory "0"        # 0 = 不限制
```

（等价操作：角色选择界面 → AddOns → 把 Script Memory 调成 0。客户端退出时会把该值写回
`Config.wtf`，所以两条路一样持久。）

新插件要**完全重启客户端**才会被枚举，`/console reloadui` 不行。

### 建新账号

```sh
bin/mangos-console.py "account create 用户名 密码"
bin/mangos-console.py "account set gmlevel 用户名 6"
```

### 验证服务端

```sh
bin/auth-check.py <账号> <密码>
```

## 单人向调整（取消团队 / 公会等限制）

一个人玩，凑不齐 40 人，也做不了要多人才能推进的前置。下面这些把服务端里
"人数 / 军衔 / 前置" 类的门槛全部拆掉。分两层：能在配置文件里关的走
`config/mangosd.conf`，写死在数据库里的走 `storage/database/custom-sql/`。

### mangosd.conf

| 项 | 原值 | 现值 | 作用 |
|---|---|---|---|
| `Instance.IgnoreRaid` | 0 | **1** | 不用组成团队就能进团本。核心的一条 |
| `Instance.IgnoreLevel` | 0 | **1** | 忽略副本的最低等级要求（奥妮 50、纳克 51 等）|
| `Instance.PerHourLimit` | 5 | **100** | 每账号每小时进副本次数。**不能填 0**——`AccountMgr::CheckInstanceCount` 里 0 表示"一个都不许进"，不是无限 |
| `Quests.IgnoreRaid` | 0 | **1** | 组成团队时也能做普通任务 |
| `MinPetitionSigns` | 9 | **0** | 公会签名数。买了公会注册表直接交给公会管理员就能建会。副作用：0 个签名即"已满"，所以别人也签不了（单机无所谓）|
| `MailDeliveryDelay` | 3600 | **0** | 给自己小号寄东西不用等一小时 |
| `Item.PreventDataMining` | 1 | **0** | 允许查询没拿到过的物品，AtlasLoot 里的物品链接才点得开 |

改完要 `docker compose restart mangosd`。备份在 `config/mangosd.conf.bak.*`。

没动但可以考虑的：`AllFlightPaths`（0 → 1 直接开全部飞行点）、`StartPlayerLevel`、
`MaxPrimaryTradeSkill`。

### storage/database/custom-sql/20-solo-raid-access.sql

配置项管不到的部分。这个目录里的 `.sql` 每次数据库容器启动都会按文件名顺序重跑
（所以写的语句都是幂等的），世界库被重建也不会丢。

| 改动 | 说明 |
|---|---|
| `areatrigger_teleport.required_condition = 0`（2848 / 3528 / 3529 / 4008 / 4010 / 4055）| 奥妮克希亚（暗炎项链）、熔火之心（钥石任务）、安其拉废墟 + 神殿、纳克萨玛斯（前置任务 9378）的入口前置 |
| `gossip_menu_option.condition_id = 0`（5750/0、6001/0）| 洛索斯·裂隙行者的"传送到熔火之心"、黑翼之巢入口的命令宝珠（原需任务 7761）|
| `variables` 30050 = 12 | 战争物资阶段推到 `WAR_EFFORT_STAGE_COMPLETE`，安其拉之门视为已开。等同 VMaNGOS 官方的 `AQ-SET_GATES_OPEN.sql` |
| `areatrigger_teleport.required_condition = 0`（2527 / 2532）| 荣誉大厅 / 冠军之厅原需 PvP 军衔 R6 |

安其拉之门那条**不能**用 `UPDATE game_event SET disabled = 1 WHERE entry = 83`——
硬编码的 `WarEffortEvent` 每个 tick 都按 `variables` 里的阶段号把事件 83 重新
`EnableAndStartEvent`，手动禁用撑不过一次 tick。改阶段号才是唯一稳的做法。

战场出口和侏儒区传送器的 condition 是阵营判断，故意没碰。

恢复原样：删掉 `20-solo-raid-access.sql`，把同目录的
`revert-solo-raid-access.sql.example` 改名成 `.sql` 跑一次。

### 已有的两处（更早做的）

- `config/mangosd.conf` 的 `Rate.Creature.Elite.*.SpellDamage` 下调
- `storage/database/custom-sql/10-solo-friendly-creatures.sql`：所有生物的
  生命/近战伤害倍率压到普通怪的 p90（精英、稀有精英、世界 BOSS 一视同仁），
  恢复见 `revert-solo-friendly-creatures.sql.example`

### 还是进不去的地方

| 情况 | 办法 |
|---|---|
| 黑翼之巢的正门（命令宝珠）在黑石塔上层深处，要先把黑石塔一长串路走完 | 上面的 SQL 只解开了宝珠的任务前置；懒得走就直接 `.tele bwl` |
| Boss 机制本身要多人（勒什雷尔的控制宝珠、四骑士等）| 只能 GM 手段绕过 |

服务端里已经有全部团本的传送点，GM 账号直接用：

```
.tele mc      .tele bwl     .tele onyxia   .tele zg
.tele aq20    .tele aq40    .tele nax
```

副本进度锁（MC/BWL/AQ40/纳克 7 天，奥妮 5 天，ZG/AQ20 3 天）没改，想重刷用
`.instance unbind all`，或从控制台 `server resetallraids`。

## 跨阵营（部落 / 联盟互不敌对）

部落角色可以走进暴风城、铁炉堡、达纳苏斯，城卫和 NPC 不动手，任务照接照交，
奖励拿到手能用。反过来也一样（联盟进奥格瑞玛等）。

### 为什么改的是 Faction.dbc，不是 NPC 的 faction

VMaNGOS 的 `WorldObject::GetFactionReactionTo()`（`src/game/Objects/Object.cpp`）
里有这么一段：只要 NPC 所属阵营 `CanHaveReputation()`——也就是
`Faction.dbc` 的 `reputationListID >= 0`——敌对与否就**完全**由玩家对该阵营的
声望等级决定，`FactionTemplate.dbc` 那套 alliance / horde 掩码整段被跳过。

主城 NPC、城卫、任务发布者用的都是有声望条的阵营（暴风城 72、铁炉堡 47、
达纳苏斯 69、侏儒 54）。所以只要把"部落种族对暴风城"的起始声望从 -42000（仇恨）
抬到 0（中立），整座城自动就不动手了。挨个改几千个 NPC 的 `creature_template.faction`
是白费力气，还会把守卫对真正敌人的反应一起弄坏。

**客户端一个字节都不用改。** 1.12 客户端算名牌颜色和右键光标，用的是服务器下发的
`SMSG_INITIALIZE_FACTIONS`（standing + flags），不是本地 DBC 里的初始值。

### 改了什么

`bin/patch-faction-dbc.py` —— 直接改
`storage/mangosd/extracted-data/5875/dbc/Faction.dbc`，13 个声望槽的
`base` 从 -42000 改成 0、去掉 `FACTION_FLAG_AT_WAR`：

| 阵营 | id | flags 结果 |
|---|---|---|
| Stormwind / Ironforge / Darnassus / Gnomeregan Exiles | 72 / 47 / 69 / 54 | `VISIBLE` |
| Orgrimmar / Thunder Bluff / Darkspear / Undercity | 76 / 81 / 530 / 68 | `VISIBLE` |
| Wildhammer Clan（辛特兰）| 471 | `VISIBLE` |
| Wintersaber / Ravasaur Trainers（阵营限定坐骑）| 589 / 630 | `VISIBLE` |
| Alliance / Horde（隐藏的总阵营）| 469 / 67 | 保持隐藏，只去掉开战位 |

flags 用 `VISIBLE` 而不是 `PEACE_FORCED`，是为了让这些阵营出现在你的声望面板里：
可以刷、可以换坐骑，也可以**随手宣战**——有部落任务要杀联盟兵的时候用得上，
点一下就打得动，打完再停战。

`storage/database/custom-sql/30-cross-faction.sql` —— 数据库这半边：

| 改动 | 行数 | 说明 |
|---|---|---|
| `quest_template.RequiredRaces = 0` | 696 | 332 个联盟专属 + 309 个部落专属 + 各族起始任务链 |
| `item_template.allowable_race = -1` | 1769 | 不放开的话交完任务奖励是灰的。坐骑也一起放开 |
| `creature_template.trainer_race = 0` | 32 | 主要是各族坐骑训练师，不放开会说"我没什么可教你的" |

阵营坐骑的**声望**门槛（崇敬）保留没动——现在部落也刷得动暴风城声望，正好当个目标。

战场阵营（奥山霜狼 729 / 石锤 730、战歌 889 / 890、阿拉希 509 / 510）故意没碰，
碰了 BG 会坏掉。安其拉、木喉、辛迪加、血帆这些两边都仇视的中立阵营同理。
战场出口和侏儒区传送器的 condition 也还是阵营判断，仍然没碰。

### 已有角色

`character_reputation.standing` 存的是**相对 base 的增量**，所以老角色的
`standing = 0` 会跟着新 base 一起变成中立，不用动。要动的只有存下来的 `flags`
（`ReputationMgr::LoadFromDB` 会拿 DB 里的 `AT_WAR` 位重新 `SetAtWar(true)`）。
已经对现有角色执行过一次：

```sql
UPDATE characters.character_reputation SET flags = 0x01
  WHERE faction IN (72,47,69,54,76,81,530,68,471,589,630) AND (flags & 0x02);
UPDATE characters.character_reputation SET flags = flags & ~0x02
  WHERE faction IN (469,67) AND (flags & 0x02);
```

新建的角色不需要这一步，创建时直接读新 DBC。

### 还没跨的：飞行点

`ObjectMgr::GetNearestTaxiNode()` 按 `TaxiNodesEntry::MountCreatureID[team]` 过滤，
联盟航点的部落槽是 0，所以部落角色在暴风城飞行管理员那里拿不到航线。
要跨得改 `TaxiNodes.dbc` 把两个槽都填上，而且客户端的 `TaxiNodes.dbc` 得跟着改
（要打 `patch-B.MPQ`），不像声望这样单边就够。暂时的替代：`mangosd.conf` 的
`AllFlightPaths = 1`，或者 GM 的 `.go`。

### 恢复

```
bin/patch-faction-dbc.py --revert && docker compose restart mangosd
rm vmangos-deploy/storage/database/custom-sql/30-cross-faction.sql
docker compose exec -T database sh -c 'mariadb -umangos -pmangos mangos' \
  < vmangos-deploy/storage/database/custom-sql/revert-cross-faction.sql.example
```

⚠️ `Faction.dbc` 的补丁在**提取出来的服务端数据**里，重跑 `bin/02-extract-server-data.sh`
会被原始 DBC 覆盖，之后要再跑一次 `bin/patch-faction-dbc.py`。原始文件留在同目录的
`Faction.dbc.orig`。

## 已知状态

- `maps` / `vmaps` / `dbc` / `mmaps` 全部提取完毕（mmaps 2002 个 mmtile / 1.9 GB）。
  重跑提取见 `bin/02a-*` / `bin/02b-*`，跑完用 `bin/04-mmaps-then-restart.sh` 加载。
  **提取是在本机做的**：`extracted-data` 已 rsync 到线上（10716 个文件逐一比对大小一致）。
  以后重跑提取，跑完要再同步一次：

  ```sh
  rsync -a --delete \
    vmangos-deploy/storage/mangosd/extracted-data/ \
    "$SERVER_SSH_USER@$SERVER_HOST":/opt/vmangos/storage/mangosd/extracted-data/
  ssh "$SERVER_SSH_USER@$SERVER_HOST" 'cd /opt/vmangos && docker compose restart mangosd'
  ```

  macOS 自带的是 openrsync，不认 `--info=progress2` / `--no-inc-recursive`，别加。

- 改了 `config/mangosd.conf` 之后要推到线上再重启（线上是单文件 bind mount，
  同样不能在远程 `sed -i`——换 inode 会断挂载，必须整文件覆盖）：

  ```sh
  scp vmangos-deploy/config/mangosd.conf "$SERVER_SSH_USER@$SERVER_HOST":/opt/vmangos/config/
  ssh "$SERVER_SSH_USER@$SERVER_HOST" 'cd /opt/vmangos && docker compose restart mangosd'
  ```

## 重要配置：StrictVersionCheck = 0

`config/realmd.conf` 里设了 `StrictVersionCheck = 0`（默认是 1）。

开启该项时 realmd 会校验客户端二进制的 integrity hash（`realmd.allowed_clients` 里
1.12.1 enUS Win x86 那条是 `95EDB27C7823B363CBDDAB56A392E7CB73FCCA20`），任何非逐字节
一致的二进制都过不了。我们跑的是 vanilla-tweaks 产出的 `WoW_tweaked.exe`，按这个机制
就属于"改过的客户端"，所以这一项保持关闭。

症状是 realmd 日志 `tried to login with modified client!`、客户端显示
`Login failed: Version mismatch`。**SRP6 密码校验本身不受影响**——失败只发生在版本证明
这一步，所以很容易误判成账号或密码问题，用 `bin/auth-check.py` 可以把两者分开。

## Claude Code Skill

`.claude/skills/vanilla-wow-local/` 是一个 **submodule**，指向
[vvenv/wow-vanilla-server-mac](https://github.com/vvenv/wow-vanilla-server-mac) ——
同一套流程打包成的 Claude Code Skill，单独一个仓库是为了能在别的项目里也用上。
克隆本仓库时带上它：

```sh
git clone --recurse-submodules https://github.com/vvenv/wow.git
# 已经克隆过了：
git submodule update --init
```

改 skill 请到那个仓库里改，这边只跟一个指针 —— 两处各改一份必然漂移。

## 关于游戏资源

本仓库**不包含也不分发任何暴雪的游戏资源、二进制或代码**。所有 MPQ、DBC、美术资源
都需要你自行提供一份合法取得的 1.12.1 客户端；文档只说明如何验证与提取。
`client/`、`client-zhCN/`、`vmangos-deploy/`、`addons/`、`downloads/` 全部在 `.gitignore` 里。

`addons/` 装的是第三方插件，各有各的来源和许可，由 `bin/install-addons.sh` 按需拉取，
不随本仓库分发。

## License

MIT，见 [LICENSE](LICENSE)。上游组件（VMaNGOS、vmangos-deploy、WoWSilicon、DXVK、
各插件）各自遵循其原本的许可。
