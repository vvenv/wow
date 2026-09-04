import AppKit

enum LaunchError: LocalizedError {
    case clientMissing(String)
    case alreadyRunning
    case noAddress
    case write(String)

    var errorDescription: String? {
        switch self {
        case .clientMissing(let p): return "找不到客户端目录：\(p)"
        case .alreadyRunning:
            return "游戏已经开着了。\n\n先退出再启动 —— 客户端退出时会把 Config.wtf 整个写回去，"
                 + "现在改的任何设置都会被它覆盖掉。"
        case .noAddress: return "服务器地址是空的。"
        case .write(let m): return "写配置失败：\(m)"
        }
    }
}

/// 起飞之后还有活要干（等窗口出来挪屏、做全屏），
/// 这期间关掉最后一个窗口不能让 app 退出
var waitingForGame = false

/// 起飞之后怎么把窗口弄成「满屏」。
///
/// 为什么分两种：**在非主显示器上做 macOS 原生全屏，这个客户端会黑屏**。
/// 逐项测出来的 ——
///
///     主屏 窗口 + 一次 Reset（1512x945 → 917）      有画面
///     副屏 窗口，全屏之前（1352x878）                有画面
///     主屏 原生全屏（Reset → 1512x949）              有画面
///     副屏 原生全屏（Reset → 1920x1080）             黑（有指针、有声音，CPU 126%）
///
/// 所以坏的既不是 D3D 的 Reset（主屏那两次都 Reset 了，没事），也不是原生全屏
/// 本身。注意主屏那次全屏后客户区是 1512x949 —— 工作区，没铺满整屏；副屏那次是
/// 1920x1080，正好等于整块屏。Wine 的 macdrv 对「窗口恰好等于整屏」有自己一套
/// fullscreen 处理，跟 macOS 的全屏 Space 撞在一起就黑。
enum FillMode {
    /// 不动尺寸，就是个窗口
    case none
    /// macOS 原生全屏。自带一个 Space，三指滑就能切进切出 —— 只在主屏上用。
    case nativeFullScreen
    /// 无边框窗口铺满目标屏。没有专属 Space，但在副屏上这是唯一不黑的走法。
    case coverScreen
}

/// 这次怎么起飞。在写 Config.wtf 之前就要定下来 ——
/// 走哪条决定了写进去的窗口 cvar 和分辨率。
enum LaunchPlan {
    /// 窗口模式起飞，等窗口出来再用辅助功能 API 挪到目标屏、按 fill 摆成满屏。
    /// 显示器排列一点都不用碰。
    case native(target: DisplayInfo?, fill: FillMode)
    /// 就在当前主屏开，execv 换掉自己。
    case plain

    var isNative: Bool { if case .native = self { return true }; return false }

    var fill: FillMode {
        switch self {
        case .native(_, let f): return f
        case .plain:            return .none
        }
    }

    var target: DisplayInfo? {
        switch self {
        case .native(let t, _):  return t
        case .plain:             return nil
        }
    }
}

enum Launcher {

    // -----------------------------------------------------------------
    // 客户端在不在跑
    // -----------------------------------------------------------------
    static func gameIsRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", #"WoW(_tweaked)?\.exe"#]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // -----------------------------------------------------------------
    // 把设置落到磁盘上
    //
    // Config.wtf 是客户端退出时会整个重写的文件，所以这里只在启动前一刻写，
    // 而且写完立刻 exec —— 中间不留窗口给别人覆盖。
    // -----------------------------------------------------------------
    static func apply(_ s: Settings, plan: LaunchPlan, uiScale: Double, volumes: Volumes) throws {
        let dir = Paths.clientDir(s.language)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw LaunchError.clientMissing(dir.path)
        }
        let address = s.serverAddress
        guard !address.isEmpty else { throw LaunchError.noAddress }

        var cfg = ConfigWTF(Paths.configWTF(s.language))

        // 语言：MPQ 决定了目录，locale 必须跟着，不然客户端找不到 Data/<locale>
        cfg.set("locale", s.language.rawValue)

        // 服务器：realmlist.wtf 是启动时读的，Config.wtf 是退出时回写的，
        // 只改一个会被另一个覆盖回去 —— 两处都得改。
        cfg.set("realmList", address)
        let realmline = "set realmlist \(address)\n"
        do { try realmline.write(to: Paths.realmlistWTF(s.language), atomically: true, encoding: .utf8) }
        catch { throw LaunchError.write(error.localizedDescription) }

        // 显示模式。
        let target = plan.target ?? Displays.main

        // 两条满屏的路都要**窗口** cvar（gxWindow 1 + gxMaximize 0），原因不同：
        // - nativeFullScreen：Wine 的 adjustFullScreenBehavior: 明确排除 maximized
        //   的窗口，gxMaximize=1 根本拿不到全屏按钮。
        // - coverScreen：gxMaximize=1 开出来的是个 popup（没有 WS_CAPTION），
        //   Wine 那边确实没标题栏 —— 但它**不可缩放**，AXSize 直接被忽略，
        //   窗口会一直是主屏那么大（实测：挪到副屏了，尺寸纹丝不动 1512x982）。
        //   而 coverScreen 就是靠 AXSize 把窗口拉到目标屏那么大的，所以只能用
        //   带标题栏的可缩放窗口，代价是顶上留一条标题栏。
        let native = plan.isNative
        switch plan.fill {
        case .nativeFullScreen, .coverScreen: cfg.set(DisplayMode.windowed.cvars)
        case .none:                           cfg.set(s.displayMode.cvars)
        }

        // gxResolution 必须是**主适配器**认的档位，跟游戏最后跑在哪块屏没关系。
        // 不在那张表里客户端就直接掉回 800x600（实测：1512x850 合桌面但不在表里
        // → 800x600），而副屏的原生分辨率几乎注定不在主屏那张表里 —— 原来按目标屏
        // 尺寸写，正是「在副屏全屏了但画面没填满」的根。
        //
        // 真正跑起来的尺寸不靠它：客户端跟着窗口大小 Reset，进原生全屏之后自己
        // 就变成目标屏的尺寸，一比一，不拉伸。详见 Displays.primaryModes。
        //
        // 三条路都要写 —— 「无边框满屏 + 没有辅助功能授权」那条原来一个字都不写，
        // 于是沿用上次退出时客户端回写的值，同样会掉 800x600。
        let picked = s.resolution.split(separator: "x").compactMap { Int($0) }
        let size: (w: Int, h: Int)
        if native && s.displayMode == .borderless {
            size = Displays.safeWindowSize(retina: s.retinaMode)
        } else if s.displayMode.usesResolution, s.resolution != "auto", picked.count == 2 {
            size = Displays.snap(picked[0], picked[1], retina: s.retinaMode)
        } else {
            // auto，以及无边框但走不了原生全屏（gxMaximize=1）那条
            let d = Displays.desktopSize(Displays.main, retina: s.retinaMode)
            size = Displays.snap(d.w, d.h, retina: s.retinaMode)
        }
        cfg.set("gxResolution", "\(size.w)x\(size.h)")
        cfg.set("gxRefresh", String(target?.refresh ?? 60))
        cfg.set("gxApi", "d3d9")            // DXVK 的 d3d9.dll 认这个

        // 画质：只有明确选了预设才动
        cfg.set(s.quality.cvars)

        // 客户端自己写的是定点小数（"0.400000"），跟着来 ——
        // String(0.3) 会变成 "0.3"，滑块上的值还可能拖出 "0.30000000000000004"。
        func f(_ d: Double) -> String { String(format: "%.6f", d) }
        cfg.set("uiScale", f(uiScale))
        cfg.set("MasterVolume", f(volumes.master))
        cfg.set("MusicVolume", f(volumes.music))
        cfg.set("SoundVolume", f(volumes.sound))
        cfg.set("AmbienceVolume", f(volumes.ambience))

        do { try cfg.write(to: Paths.configWTF(s.language)) }
        catch { throw LaunchError.write(error.localizedDescription) }

        try applyFpsCap(s)
    }

    /// 帧率上限归 DXVK 管，不是游戏 cvar。
    private static func applyFpsCap(_ s: Settings) throws {
        let url = Paths.dxvkConf(s.language)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let wanted = s.fpsCap > 0
            ? "d3d9.maxFrameRate = \(s.fpsCap)"
            : "# d3d9.maxFrameRate = 144"
        var lines = text.components(separatedBy: "\n")
        var found = false
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("d3d9.maxFrameRate") || t.hasPrefix("# d3d9.maxFrameRate") {
                lines[i] = wanted
                found = true
            }
        }
        if !found { lines.append(wanted) }
        text = lines.joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw LaunchError.write(error.localizedDescription) }
    }

    // -----------------------------------------------------------------
    // Wine 的 Retina 模式
    //
    // 关着的时候 Wine 按「点」看屏幕（1512x982），开了就按真实像素
    // （3024x1964）—— 画面锐利四倍的像素量，代价是原版 UI 变得很小。
    // 这个开关落在 Wine prefix 的注册表里，是全 prefix 共享的状态，
    // 所以走 wine reg 而不是手改 user.reg。
    // -----------------------------------------------------------------
    static func currentRetinaMode() -> Bool {
        guard let reg = try? String(contentsOf: URL(fileURLWithPath:
                NSHomeDirectory() + "/.wine/user.reg"), encoding: .utf8) else { return false }
        guard let range = reg.range(of: #"[Software\\Wine\\Mac Driver]"#) else { return false }
        let section = reg[range.upperBound...].prefix(600)
        guard let line = section.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("\"RetinaMode\"") }) else { return false }
        return line.lowercased().contains("\"y\"")
    }

    @discardableResult
    static func setRetinaMode(_ on: Bool) -> Bool {
        let ws = "/Applications/WoWSilicon.app/Contents/Resources"
        let wine = "\(ws)/Wine/bin/wine"
        guard FileManager.default.isExecutableFile(atPath: wine) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: wine)
        p.arguments = ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#,
                       "/v", "RetinaMode", "/t", "REG_SZ", "/d", on ? "y" : "n", "/f"]
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = "\(ws)/Wine/lib/external"
        env["ROSETTA_X87_PATH"] =
            "\(ws)/WoWSilicon-swift_WoWSiliconSwift.bundle/Patching/rosettax87/rosettax87"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // -----------------------------------------------------------------
    // 起飞
    //
    // 两条路，plan(_:) 里决定走哪条：
    //
    // - native  —— 窗口模式起飞，等窗口出来用辅助功能 API 挪到目标屏、
    //   进 macOS 原生全屏。显示器排列一点都不碰，菜单栏和 Dock 不搬家，
    //   而且原生全屏自带一个 Space。做完就 exit，返回 true —— 调用方别再
    //   开面板，让 run loop 转着。
    // - plain —— execv 换掉自己。Dock 上那个图标直接变成游戏，
    //   不留一个启动器进程在旁边占位置。
    //
    // 曾经还有第三条「临时把目标屏设成主显示器」当兜底，已经删掉：它要把
    // 菜单栏和 Dock 都搬到副屏，还得留个进程守到游戏退出才能摆回排列，
    // 代价比它解决的问题大。没有辅助功能授权就老实走 plain，面板会说清楚。
    // -----------------------------------------------------------------

    /// 这次怎么起飞。apply 和 start 都要用同一份，所以做成纯函数各自算一遍，
    /// 别让两边算出不一样的东西。
    static func plan(_ s: Settings) -> LaunchPlan {
        let target = Displays.resolve(s.preferredDisplay)

        // 独占全屏不走原生全屏：客户端自己去换显示模式了，
        // 没有一个普通窗口可以交给 macOS。
        if s.displayMode != .fullscreen, Native.trusted {
            let needsMove = !(target?.isMain ?? true)
            // 满屏怎么做取决于在哪块屏：主屏用 macOS 原生全屏（白拿一个 Space），
            // 副屏只能用无边框铺满 —— 原生全屏在副屏上会黑，见 FillMode。
            let fill: FillMode = s.displayMode == .borderless
                ? (needsMove ? .coverScreen : .nativeFullScreen)
                : .none
            // 窗口模式又不用挪屏的话没什么可做的，让它走 execv 更干净
            if fill != .none || needsMove {
                return .native(target: target, fill: fill)
            }
        }
        return .plain
    }

    @discardableResult
    static func start(_ s: Settings, plan: LaunchPlan) throws -> Bool {
        guard !gameIsRunning() else { throw LaunchError.alreadyRunning }

        switch plan {
        case .native(let target, let fill):
            try spawn(s)
            detach {
                Native.place(on: target, fill: fill)
                // 全屏切换的动画交给 WindowServer，稍等一下再走
                Thread.sleep(forTimeInterval: 1.5)
                // 这条路没有需要恢复的东西，活儿干完直接退
                exit(0)
            }
            return true

        case .plain:
            try exec(s)
        }
    }

    /// 起游戏进程（不换掉自己），stdout/stderr 接到日志。
    private static func spawn(_ s: Settings) throws {
        let p = Process()
        p.executableURL = Paths.playScript
        p.arguments = [s.language.folder]
        var env = ProcessInfo.processInfo.environment
        // play-wine.sh 默认会自己写 gxWindow/gxMaximize。设置已经写好了，
        // 让它别插手 —— 不然「独占全屏」会被它按回窗口。
        env["WINDOWED"] = "0"
        // Finder 起的 .app 环境很干净，play-wine.sh 用到 sed/grep/awk，保底给个 PATH
        if (env["PATH"] ?? "").isEmpty { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        p.environment = env

        let log = Paths.logFile(s.language)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) {
            p.standardOutput = h
            p.standardError = h
        }
        do { try p.run() } catch { throw LaunchError.write(error.localizedDescription) }
    }

    /// 收起面板、从 Dock 消失，然后把剩下的活儿丢到后台线程。
    /// 主线程得留给 run loop，不然窗口关不掉、进程还会被系统标成「无响应」。
    private static func detach(_ body: @escaping () -> Void) {
        waitingForGame = true
        // NSApplication.shared 而不是 NSApp：跳过面板那条路上 AppKit 还没起来，
        // NSApp 是 nil，碰一下就崩（踩过）。
        let app = NSApplication.shared
        app.windows.forEach { $0.close() }
        app.setActivationPolicy(.accessory)
        Thread.detachNewThread(body)
    }

    private static func exec(_ s: Settings) throws -> Never {
        let log = Paths.logFile(s.language).path
        freopen(log, "w", stdout)
        freopen(log, "w", stderr)

        // play-wine.sh 默认会自己写 gxWindow/gxMaximize。设置已经由面板写好了，
        // 让它别插手 —— 不然「独占全屏」会被它按回窗口。
        setenv("WINDOWED", "0", 1)

        // Finder 起的 .app 环境很干净。play-wine.sh 用到 sed/grep/awk，
        // 保底给一个 PATH。
        if String(cString: getenv("PATH") ?? strdup("")).isEmpty {
            setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        }

        let script = Paths.playScript.path
        let folder = s.language.folder
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(script), strdup(folder), nil,
        ]
        execv(script, argv)
        // 只有 execv 失败才会走到这
        fputs("execv \(script) 失败: \(String(cString: strerror(errno)))\n", stderr)
        exit(127)
    }
}

struct Volumes {
    var master: Double = 1
    var music: Double = 0.4
    var sound: Double = 1
    var ambience: Double = 0.6

    static func read(_ l: Language) -> Volumes {
        let cfg = ConfigWTF(Paths.configWTF(l))
        return Volumes(master: cfg.double("MasterVolume", 1),
                       music: cfg.double("MusicVolume", 0.4),
                       sound: cfg.double("SoundVolume", 1),
                       ambience: cfg.double("AmbienceVolume", 0.6))
    }
}
