# 客户端：用 WoWSilicon 的 Wine 跑原版 1.12.1 二进制

## 为什么是这条路

原版 Blizzard `WoW.exe` 就是行为的参考实现 —— 重实现客户端的所有协议/UI 缺口在它身上
根本不存在。代价是走翻译层，不是原生 ARM64。

| 方案 | 结论 |
|---|---|
| **WoWSilicon** | ✅ 自带 Wine 运行时，免费 GPLv3，要求 Apple Silicon + macOS 15+ |
| TurtleSilicon | 同类启动器，但**依赖 CrossOver ≥25.0.1（付费）**，一般没必要 |
| 原生 macOS 1.12.1 客户端 | ❌ 不存在可用的。当年 Mac 版是 PPC + i386 通用二进制，32 位 Intel 自 Catalina 起无法运行 |
| 开源重实现客户端 | ❌ 已评估并放弃：协议/UI 缺口太多，且改过的二进制过不了 `StrictVersionCheck` |

> ⚠️ **Whisky 已于 2025-04 停止开发。** 网上大量教程仍在推荐它，不要再照做。

## 安装

[官网](https://wowsilicon.github.io/) · [GitHub](https://github.com/WoWSilicon/WoWSilicon)

内置 profile：`VanillaSilicon (1.12.1)` / `BurningSilicon (2.4.3)` / `WrathSilicon (3.3.5a)`；
图形后端可选 `d9vk`（Vulkan）或 `mtld3d`（Metal 原生，支持 HDR）。

```sh
# 取最新版本（发布页不一定列出版本号，用 API 更可靠）
curl -s https://api.github.com/repos/WoWSilicon/WoWSilicon/releases/latest \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['tag_name']);\
[print(a['browser_download_url']) for a in d['assets']]"

hdiutil attach WoWSilicon-<ver>.dmg -nobrowse -quiet
cp -R /Volumes/WoWSilicon/WoWSilicon.app /Applications/
hdiutil detach /Volumes/WoWSilicon -quiet
```

**签名说明**：ad-hoc 签名（`TeamIdentifier=not set`），`spctl` 会报 rejected。但用
`aria2c`/`curl` 下载不会打 `com.apple.quarantine` 标记，因此可直接运行，**不需要绕过
Gatekeeper**。先 `xattr -l` 确认再决定。

## 配置文件可直接预填，不必手点

```
~/Library/Application Support/WoWSilicon/prefs.json      # 全局偏好
~/Library/Application Support/WoWSilicon/versions.json   # 各 profile 的 game_path 等
```

**编辑前先退出应用**，否则退出时会覆盖你的改动。

```python
import json, os
p = os.path.expanduser("~/Library/Application Support/WoWSilicon/versions.json")
d = json.load(open(p))
d["currentVersionID"] = "vanillasilicon"
d["versions"]["vanillasilicon"]["game_path"] = "/path/to/WoW-1.12.1"
json.dump(d, open(p, "w"), indent=2)
```

> `game_path` 用**符号链接是可以的**（实测 Wine 正常跑）。这样客户端目录可以直接指向
> 服务端的 `vmangos-deploy/storage/mangosd/client-data`，一份 MPQ 两处用，省约 5 GB。

## ⚠️ 坑一：改 realmlist.wtf 不够，Config.wtf 会覆盖它

这是最常见的"改完还是连不上"。**两处都要改**：

```sh
echo "set realmlist 127.0.0.1" > "$GAME/realmlist.wtf"
sed -i '' 's|SET realmList ".*"|SET realmList "127.0.0.1"|' "$GAME/WTF/Config.wtf"
```

`WTF/Config.wtf` 里缓存的 `SET realmList` **优先级更高**。第三方整合包（如 Stonetavern）
两处都预设成了它们自己的服务器地址。

## ⚠️ 坑二：Play 按钮在补丁未应用前静默失败

应用**不写任何日志**，从终端启动也没有 stdout 输出，点 Play 毫无反应——很难定位。

补丁素材在应用包内：

```
/Applications/WoWSilicon.app/Contents/Resources/\
WoWSilicon-swift_WoWSiliconSwift.bundle/Patching/
├── winerosetta/{winerosetta.dll, libDllLdr.dll}
├── d9vk/d3d9.dll
├── rosettax87/{rosettax87, libRuntimeRosettax87}
├── x87sidecar/x87sidecar
├── libSiliconPatch/{vanilla,wotlk}/libSiliconPatch.dll
└── vanilla-tweaks/
```

**打好补丁的游戏目录应当满足**（可用来判断是否就绪）：

```sh
GAME=/path/to/WoW-1.12.1
test -f "$GAME/mods/winerosetta.dll"       # 必须
test -f "$GAME/mods/libDllLdr.dll"         # 必须
test -f "$GAME/d3d9.dll"                   # 根目录，D9VK
grep -q "mods/winerosetta.dll" "$GAME/dlls.txt"   # 链式加载清单，见 addons-and-mods.md
```

`scripts/wowsilicon-setup.sh` 会检查并补齐这些。

> 应用自身也会做一部分补丁（例如备份并替换 `DivxDecoder.dll` —— 那个替换正是
> `dlls.txt` 生效的原因）。优先在 UI 里完成它提供的 patch 步骤；上面的手动补齐用于
> UI 静默失败时兜底。

## 手动启动（UI 完全用不了时的兜底）

从实际运行的进程抓到的命令行，绕开启动器直接跑：

```sh
GAME=/path/to/WoW-1.12.1
APP=/Applications/WoWSilicon.app/Contents/Resources
cd "$GAME" && \
ROSETTA_X87_PATH="$APP/WoWSilicon-swift_WoWSiliconSwift.bundle/Patching/rosettax87/rosettax87" \
DYLD_LIBRARY_PATH="$APP/Wine/lib/external" \
WINE_LARGE_ADDRESS_AWARE=1 \
WINEDLLOVERRIDES="d3d9=n" \
MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 \
DXVK_ASYNC=1 \
"$APP/Wine/bin/wine" "$GAME/WoW.exe"
```

`scripts/wowsilicon-launch.sh` 就是这条命令的封装。既然可以直接起 exe，就可以包一个
`.app` 壳把 WoWSilicon 的 UI 整个绕过去，省掉在里面来回改 Game Path。**一个壳能管多个
客户端目录**：语言、地址、窗口模式全在 `Config.wtf` 里，壳先按选择把文件写好再 `exec`
启动脚本即可，不需要每个目录一个壳。

> rosettax87 已经处理了 x87/RDTSC，所以**不需要用 `VanillaFixes.exe` 当启动器**。
> 但这不代表 VanillaFixes 的补丁没生效 —— 见 `addons-and-mods.md` 的加载链。

## ⚠️ 坑三：默认就是独占全屏，而独占全屏在 Wine 下会挂

窗口模式由 `Config.wtf` 里两个 cvar 决定：

| `gxWindow` | `gxMaximize` | 效果 |
|---|---|---|
| `1` | `1` | 无边框满屏 —— **用这个** |
| `1` | `0` | 普通窗口，尺寸取 `gxResolution` |
| `0` | `0` | 独占全屏（DirectX 换显示模式）|

**这两行经常根本不在文件里。** 客户端退出时会重写 `Config.wtf`，只写它认为非默认的
cvar —— 实测 `gxWindow` / `gxMaximize` 会被整行删掉，同时 `gxResolution` 被打回
`800x600`。缺行时客户端按内置默认走，也就是独占全屏，表现成"什么都没改，下次开就全屏了"。
每次启动前显式写这两行，别指望文件里留着。

独占全屏在 Wine 下切回桌面时模式切换会挂死，游戏里按 Alt+Enter 同理。无边框满屏视觉上
完全一样，而且 Cmd-Tab 是稳的。DXVK 那边也要一起关掉：

```
dxvk.allowFse = False        # client 目录的 dxvk.conf
```

顺带：帧率上限走 DXVK 的 `d3d9.maxFrameRate`，不是游戏 cvar —— 1.12 没有帧率上限设置。

## 让游戏开在副屏 / 让它独占一个 Space

**1.12 的客户端没法被告知用哪块屏。** 把 exe 里的 cvar 名全捞出来看就知道：

```sh
strings -a WoW_tweaked.exe | grep -oE '^gx[A-Za-z]+$' | sort -u
# gxApi gxAspect gxColorBits gxCursor gxDepthBits gxFixLag gxMaximize gxMultisample
# gxMultisampleQuality gxOverride gxRefresh gxResolution gxRestart gxTripleBuffer
# gxVSync gxWindow
```

没有 `gxMonitor` / `gxAdapter`。它导入的是 `MonitorFromRect`，也就是**窗口落在哪块屏就在
哪块屏最大化**；而 Wine 把窗口摆在桌面原点，原点永远是主显示器。所以这件事只能在
macOS 这一侧解决。四条路，按推荐顺序：

### ✅ 推荐：辅助功能 API 挪窗口 + macOS 原生全屏

**Wine 的 Mac driver 实现了原生全屏**（`winemac.so` 里有 `toggleFullScreen:`、
`adjustFullScreenBehavior:`、`customWindowsToEnterFullScreenForWindow:`、
`setCollectionBehavior:`），而原生全屏本来就会让 macOS **自动给这个窗口开一个专属
Space** —— 等于白拿了「新建一个桌面」这件事。

实测（AX 属性直接读写）：

```
pid 35611 窗口 '魔兽世界' 全屏按钮=有 AXFullScreen=0
before: (4,30) 1280x752
搬到副屏: 成功  now: (-100,-1000) 1280x752
设 AXFullScreen=true: 成功
after:  (0,0) 1920x1080        ← 全屏 Space 自己的坐标系
```

做法：**窗口模式起飞 → 轮询到游戏窗口出现 → 设 `AXPosition` 挪到目标屏 → 设
`AXFullScreen = true`**。找窗口的路子是 `CGWindowListCopyWindowInfo` 里 owner 名为
`wine`、`kCGWindowLayer == 0` 的那个，再用 `AXUIElementCreateApplication(pid)` 拿
`kAXWindowsAttribute`，挑能取到 `kAXFullScreenButtonAttribute` 的那一个。

> ⚠️ **wine 不在前台的时候，`kAXWindows` 返回空数组。** 不是报错，`AXError` 就是
> `.success`，只是 0 个窗口 —— 查不出任何毛病，看起来像「窗口还没出来」。启动器起完
> 游戏通常会把自己收起来（切 accessory），游戏那个 app 从来没被激活过，于是轮询永远
> 等不到窗口。**先 `NSRunningApplication(processIdentifier:)?.activate()` 再查。**
> 反正玩家本来就要游戏在前台，不算副作用。

`AXUIElementSetAttributeValue(win, "AXFullScreen", true)` 返回 `.success` 也只代表消息
送到了，不代表窗口真进了全屏 —— 游戏刚起来那几秒 Wine 那边还在忙，会把这一下吃掉。
**设完要回读确认，不成再试几次。**

两个前提，都是硬的：

- **必须窗口模式**（`gxWindow "1"` + `gxMaximize "0"`）。Wine 的 `adjustFullScreenBehavior:`
  明确排除 maximized 的窗口，无边框满屏拿不到全屏按钮。所以「无边框满屏」这个选项在这条路上
  写的是窗口 cvar，满屏是一会儿交给 macOS 做的。
- **需要辅助功能授权**（`AXIsProcessTrusted()` 先查；`AXIsProcessTrustedWithOptions` 带
  `kAXTrustedCheckOptionPrompt` 可以弹一次系统对话框，顺带把 app 加进设置里那张列表）。

### ⚠️ ad-hoc 签名的壳每次重新编译都会掉辅助功能授权

TCC 记的不是路径也不是 bundle id，是**指定要求**。ad-hoc 签名（`codesign -s -`）的指定要求
是一串 cdhash：

```sh
codesign -d -r- WoW.app
# designated => cdhash H"a9c806b081e2ccf0acf2a055936eaa185fc45b51"
```

二进制一变 cdhash 就变，授权立刻失效，而且**系统设置里那个开关看着还是开的** —— 这是最
坑的地方，看起来一切正常，功能就是不灵。

**解法是用一张本机自签的证书签名**，指定要求就变成跟证书绑定，重新编译多少次都不掉：

```sh
# 造证书（codeSigning EKU 必须有）
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -keyout cs.key -out cs.crt -config cs.cnf

# macOS 的 Security 框架读不了 LibreSSL 默认那套 PKCS#12 参数（导入时报
# 「MAC verification failed」），必须指定老算法 + 非空密码
openssl pkcs12 -export -out cs.p12 -inkey cs.key -in cs.crt -passout pass:xxx \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
security import cs.p12 -k ~/Library/Keychains/login.keychain-db -P xxx -T /usr/bin/codesign

# 按 SHA-1 引用身份来签
codesign --force --sign "$(openssl x509 -in cs.crt -noout -fingerprint -sha1 \
  | sed 's/.*=//; s/://g')" WoW.app
# designated => identifier "..." and certificate leaf = H"25674fc2..."
```

**不需要 sudo，也不需要 `add-trusted-cert`** —— `codesign` 按 SHA-1 引用身份时不要求这张
自签根是受信任的。`security find-identity -p codesigning` 看不到它是正常的，不影响签名。

换过签名方式之后先 `tccutil reset Accessibility <bundle-id>` 清掉旧要求的残留条目，
再让 app 自己弹一次授权框。

**尺寸要在起飞前就写成目标屏的桌面尺寸**：这样进全屏时内容区尺寸不变，客户端不用重建
交换链，也就不会被 DXVK 拉伸糊掉。

好处是显示器排列一点都不用碰，菜单栏和 Dock 不搬家，启动器把窗口安顿好就能自己退掉，
不用像换主显示器那条路一样守到游戏退出。

### ⚠️ 备选：临时把目标屏设成主显示器

没有辅助功能授权时的兜底。CoreGraphics 的 `CGBeginDisplayConfiguration` /
`CGConfigureDisplayOrigin` / `CGCompleteDisplayConfiguration` 是公开 API，**不需要任何
权限** —— 把目标屏的原点挪到 `(0,0)` 它就成了主屏。启动前换、游戏退出后换回来。

两个必须做的收尾：

- 用 `kCGConfigureForSession` 而不是 `permanently`，注销一次就复原，不会把用户的排列永久改掉。
- 动手**之前**先把原排列落盘。启动器要是被强杀就没人负责恢复了，下次启动时读回来补上。
  同时这意味着启动器不能 `execv` 掉自己 —— 得留个进程等游戏退出。

代价是玩的时候菜单栏和 Dock 会跟着搬到那块屏。

好用的默认值是**「壳窗口在哪块屏，就用哪块」**（`NSWindow.screen` → `NSScreenNumber` →
`CGDirectDisplayID`）：想在哪块屏玩就把启动面板拖过去。单屏时它和"用主显示器"完全等价，
所以可以直接当默认。没有窗口的路径（记住选择、直接起飞）用 `NSEvent.mouseLocation`
所在的屏兜底 —— 用户刚在哪块屏双击的图标，鼠标就还在哪块屏。

### ❌ 自己新建 Space：需要关 SIP，别走

macOS **没有公开 API 能新建 Space**。私有的 SkyLight 那套（`CGSSpaceCreate`、
`CGSManagedDisplaySetCurrentSpace`、`CGSAddWindowsToSpaces`）必须从 Dock 进程里调 ——
yabai 的做法是往 Dock 注入 scripting addition，**要求关掉 SIP**。先查一下再考虑：

```sh
csrutil status          # enabled 就别想了
```

上面那条原生全屏的路等于绕开了这个限制：Space 是 macOS 替你建的。

### ❌ Wine 虚拟桌面：这个 Wine 里跑不起来

`wine explorer /desktop=wow,1920x1080` 本来是最干净的做法，但 WoWSilicon 这个 Wine 里
`explorer.exe` 自己就崩（SEH 异常）。别在这上面花时间。

### 纯手工：什么都不用写

游戏窗口是 layer 0 的普通层级窗口（不是浮动层），按 F3 打开调度中心把缩略图拖到别的
桌面就行，或者 Dock 图标右键 → 选项 → 指定给 → 桌面 N（这个 macOS 会记住）。

## 改 Config.wtf 的规矩

- **客户端退出时会把整个 `Config.wtf` 重写一遍。** 所以任何外部修改都必须在客户端**没在跑**
  的时候做，否则退出瞬间被覆盖。`pgrep -f 'WoW(_tweaked)?\.exe'` 先拦一道。
- 逐行 `SET key "value"` 解析、**保留不认识的行**再整体写回。里面混着摄像机角度、上次登录
  的角色序号这些运行时状态，重排或丢弃会让客户端行为发生莫名变化。
- 数值客户端自己写的是定点格式（`SET uiScale "1.000000"`），外部改的时候按 `%.6f` 写，
  别写成 `1.0`。

## 坐标单位：Wine 报点，DXVK 报像素

Wine 的 Mac driver 默认按**点**（point）汇报屏幕和窗口尺寸，`HKCU\Software\Wine\Mac Driver`
下的 `RetinaMode` 才切到物理像素。但**实测这两个数是分开的**：`RetinaMode` 关着的时候
Wine 报 1512x982，而同一时刻 DXVK 的交换链已经是 3024x1964 了（副屏上是 1920x1080 对
3840x2160）。

所以网上"开 Retina 模式画面才清晰"的说法在这套组合（Wine 11 + DXVK 3.0.2 + MoltenVK）里
**没能复现**。这里只记录测到的数，不下结论 —— 但据此算窗口尺寸时要清楚自己拿的是哪一个。

## 多语言 = 多个游戏目录

vanilla 的语言在启动时由 `Config.wtf` 的 `SET locale` 决定，**游戏内切不了**。要两种
语言就要两份目录：

- **能共享的**：`Interface/AddOns` 可以做成指向同一个插件目录的符号链接。前提是
  Blizzard 存根（`Blizzard_*/*.pub`）两边 `diff -rq` 一致，且插件本身按 `GetLocale()`
  运行时选语言（pfQuest 这类同时带 `db/enUS` 和 `db/zhCN` 的就可以）。
- **不能共享的**：`Data/` 的 MPQ（每一个尺寸都不同，国服还有和谐化模型）、`WTF/` 里的
  `SET locale` 和各自独立的账号状态、以及整个 DLL mod 层。

服务端会跟着客户端上报的语言自动发对应语言的任务/物品/NPC 文本，不需要额外配置。

> 中文客户端在 Wine 下**收不到 macOS 输入法送来的中文**，输入框只显示 `?`。需要按中文
> 搜索的插件必须自带拼音索引之类的 ASCII 检索路径。

## 验证跑通了

```sh
pgrep -fl "WoW.exe|wineserver"        # Wine 进程在
ls "$GAME/WoW.dxvk-cache"             # 已渲染过画面
docker compose logs realmd | grep -i authenticated   # 服务端收到登录
```

启动脚本应把 stdout/stderr 重定向到固定日志（例如 `/tmp/wow-client.log`）——启动失败
时那是唯一的线索。

> ⚠️ **`MachExc: PT_THUPDATE failed: Invalid argument` 不是死因，是死相。** 它来自
> rosettax87 的 Mach 异常处理器在进程收摊时去动一个已经没了的线程，客户端无论怎么退出
> 都可能留下这一行。看到它只能说明进程没了，**不要拿它当诊断**。真正有信息量的是它上面
> 那几行，以及客户端退出时回写的 `Config.wtf` —— 比如 `gxResolution` 变成 `800x600`
> 就说明它是在图形初始化那一步自己放弃的，而不是被外部杀掉的。
