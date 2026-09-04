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

/// 这次怎么起飞。在写 Config.wtf 之前就要定下来 ——
/// 走哪条决定了写进去的窗口 cvar 和分辨率。
enum LaunchPlan {
    /// 窗口模式起飞，等窗口出来再用辅助功能 API 挪到目标屏 / 进 macOS 原生全屏。
    /// 显示器排列一点都不用碰，而且原生全屏自带一个 Space。
    case native(target: DisplayInfo?, fullscreen: Bool)
    /// 就在当前主屏开，execv 换掉自己。
    case plain

    var isNative: Bool { if case .native = self { return true }; return false }

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

        // 显示模式。尺寸按「游戏最后会跑在哪块屏」算，不是按现在的主屏。
        let target = plan.target ?? Displays.main

        // 走原生全屏那条路时，「无边框满屏」写的是窗口 cvar ——
        // Wine 的 adjustFullScreenBehavior: 不给 maximized 的窗口全屏按钮。
        // 满屏是一会儿交给 macOS 做的，视觉结果一样，还多一个专属 Space。
        let native = plan.isNative
        cfg.set(native && s.displayMode == .borderless
                ? DisplayMode.windowed.cvars
                : s.displayMode.cvars)

        if native && s.displayMode == .borderless {
            // 尺寸必须正好是目标屏的桌面尺寸：进全屏时内容区尺寸不变，
            // 客户端就不用重建交换链，也不会被 DXVK 拉伸糊掉。
            let d = Displays.desktopSize(target, retina: s.retinaMode)
            cfg.set("gxResolution", "\(d.w)x\(d.h)")
        } else if s.displayMode.usesResolution {
            let res: String
            if s.resolution == "auto" {
                let d = Displays.desktopSize(target, retina: s.retinaMode)
                res = "\(d.w)x\(d.h)"
            } else {
                res = s.resolution
            }
            cfg.set("gxResolution", res)
        }
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
            let wantsFullscreen = s.displayMode == .borderless
            let needsMove = !(target?.isMain ?? true)
            // 窗口模式又不用挪屏的话没什么可做的，让它走 execv 更干净
            if wantsFullscreen || needsMove {
                return .native(target: target, fullscreen: wantsFullscreen)
            }
        }
        return .plain
    }

    @discardableResult
    static func start(_ s: Settings, plan: LaunchPlan) throws -> Bool {
        guard !gameIsRunning() else { throw LaunchError.alreadyRunning }

        switch plan {
        case .native(let target, let fullscreen):
            try spawn(s)
            detach {
                Native.place(on: target, fullscreen: fullscreen)
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
