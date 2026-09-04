import AppKit

// ===========================================================================
// 仓库里的位置
// ===========================================================================
enum Paths {
    /// WoW.app 就放在仓库根目录里，所以它的上一级就是根。
    /// 搬到别处（比如拖进 /Applications）就找不到客户端了 —— 那种情况下
    /// 照样返回上一级，让 LaunchError.clientMissing 把话说清楚，
    /// 而不是偷偷退回某台机器上的绝对路径。
    static let root: URL = Bundle.main.bundleURL.deletingLastPathComponent()

    static var settingsFile: URL { root.appendingPathComponent("launcher.json") }
    static var playScript: URL { root.appendingPathComponent("bin/play-wine.sh") }
    static var syncScript: URL { root.appendingPathComponent("bin/sync-characters.sh") }
    static var addonsDir: URL { root.appendingPathComponent("addons") }
    static var serverConf: URL { root.appendingPathComponent("server.conf") }

    static func clientDir(_ l: Language) -> URL { root.appendingPathComponent(l.folder) }
    static func configWTF(_ l: Language) -> URL { clientDir(l).appendingPathComponent("WTF/Config.wtf") }
    static func realmlistWTF(_ l: Language) -> URL { clientDir(l).appendingPathComponent("realmlist.wtf") }
    static func dxvkConf(_ l: Language) -> URL { clientDir(l).appendingPathComponent("dxvk.conf") }
    static func logFile(_ l: Language) -> URL {
        URL(fileURLWithPath: "/tmp/wow-\(l.folder).log")
    }

    /// Finder 起的 .app PATH 常缺 /usr/local/bin（docker）和 homebrew（sshpass）
    static func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extras = ["/usr/local/bin", "/opt/homebrew/bin", "\(home)/.docker/bin"]
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let missing = extras.filter { !base.contains($0) }
        env["PATH"] = missing.isEmpty ? base : base + ":" + missing.joined(separator: ":")
        return env
    }
}

// ===========================================================================
// 选项
// ===========================================================================
enum Language: String, CaseIterable, Codable, Identifiable {
    case zhCN, enUS
    var id: String { rawValue }
    var label: String { self == .zhCN ? "简体中文" : "English" }
    /// 仓库里的客户端目录名。两份是同一个二进制，只有 Data/ 的 MPQ 不同。
    var folder: String { self == .zhCN ? "client-zhCN" : "client" }
}

enum DisplayMode: String, CaseIterable, Codable, Identifiable {
    case borderless, windowed, fullscreen
    var id: String { rawValue }
    var label: String {
        switch self {
        // 有辅助功能授权时这一项走的是 macOS 原生全屏，早就不是「无边框窗口」了；
        // 界面上就叫「全屏」，实现细节留在说明行里讲。
        case .borderless: return "全屏"
        case .windowed:   return "窗口"
        case .fullscreen: return "独占全屏"
        }
    }
    /// 底栏摘要用的短名
    var shortLabel: String {
        switch self {
        case .borderless: return "全屏"
        case .windowed:   return "窗口"
        case .fullscreen: return "独占全屏"
        }
    }
    /// 选中时那句常驻说明。三条都控制在两行以内，页面高度才不会跟着变。
    var note: String {
        switch self {
        case .borderless:
            return "铺满整个屏幕，Cmd-Tab 切出去稳。推荐。"
        case .windowed:
            return "按下面的分辨率开一个普通窗口。"
        case .fullscreen:
            return "⚠️ Wine 下切回桌面时模式切换可能挂死。上面那个「全屏」看着一样且是稳的。"
        }
    }
    /// 无边框是最大化窗口，尺寸由桌面决定，gxResolution 用不上。
    var usesResolution: Bool { self != .borderless }
    var cvars: [String: String] {
        switch self {
        case .borderless: return ["gxWindow": "1", "gxMaximize": "1"]
        case .windowed:   return ["gxWindow": "1", "gxMaximize": "0"]
        case .fullscreen: return ["gxWindow": "0", "gxMaximize": "0"]
        }
    }
}

/// 仓库根目录的 server.conf（KEY=VALUE）。不入库 —— 线上服的地址是私事，
/// 开源出去的是流程和工具，不是某台机器的坐标。见 server.conf.example。
enum ServerConf {
    private static let values: [String: String] = {
        guard let text = try? String(contentsOf: Paths.serverConf, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !k.isEmpty { out[k] = v }
        }
        return out
    }()

    static var onlineHost: String { values["SERVER_HOST"] ?? "" }
    static var hasOnline: Bool { !onlineHost.isEmpty }
}

enum ServerPreset: String, CaseIterable, Codable, Identifiable {
    case online, local, custom
    var id: String { rawValue }
    /// 只给名字。地址统一在下面那一行「地址」里显示 ——
    /// 弹出菜单里塞 IP 会让三个选项长短不一，而且地址那行反而显得多余。
    var label: String {
        switch self {
        case .online: return "线上"
        case .local:  return "本地"
        case .custom: return "自定义"
        }
    }
    var address: String? {
        switch self {
        case .online: return ServerConf.hasOnline ? ServerConf.onlineHost : nil
        case .local:  return "127.0.0.1"
        case .custom: return nil
        }
    }

    /// 没配 server.conf 就别把「线上」摆出来 —— 一个选了也没用的选项比没有更糟
    static var available: [ServerPreset] {
        ServerConf.hasOnline ? allCases : allCases.filter { $0 != .online }
    }
}

/// 画质预设。默认是 keep —— 两个 Config.wtf 都是手调过的，
/// 不选预设就一个画质 cvar 都不碰。
enum QualityPreset: String, CaseIterable, Codable, Identifiable {
    case keep, low, medium, high, ultra
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keep:   return "保持不变"
        case .low:    return "低"
        case .medium: return "中"
        case .high:   return "高"
        case .ultra:  return "极限（超出游戏滑块上限）"
        }
    }
    /// 数值取自 1.12 视频选项的档位；shadowlod 按原版顺序 0=最低。
    var cvars: [String: String] {
        switch self {
        case .keep: return [:]
        case .low: return [
            "farclip": "177", "horizonfarclip": "2112", "unitDrawDist": "100.000000",
            "groundEffectDist": "40", "lodDist": "50", "DistCull": "300.000000",
            "SmallCull": "0.080000", "frillDensity": "0", "specular": "0",
            "pixelShaders": "0", "anisotropic": "1", "shadowlod": "0",
            "weatherDensity": "0", "doodadAnim": "0", "trilinear": "0",
            "Specularity": "0", "SkyCloudLOD": "0"]
        case .medium: return [
            "farclip": "300", "horizonfarclip": "4224", "unitDrawDist": "200.000000",
            "groundEffectDist": "70", "lodDist": "75", "DistCull": "400.000000",
            "SmallCull": "0.060000", "frillDensity": "16", "specular": "1",
            "pixelShaders": "1", "anisotropic": "4", "shadowlod": "1",
            "weatherDensity": "2", "doodadAnim": "1", "trilinear": "1",
            "Specularity": "1", "SkyCloudLOD": "2"]
        case .high: return [
            "farclip": "477", "horizonfarclip": "6226", "unitDrawDist": "300.000000",
            "groundEffectDist": "100", "lodDist": "100", "DistCull": "500.000000",
            "SmallCull": "0.040000", "frillDensity": "24", "specular": "1",
            "pixelShaders": "1", "anisotropic": "16", "shadowlod": "2",
            "weatherDensity": "3", "doodadAnim": "1", "trilinear": "1",
            "Specularity": "1", "SkyCloudLOD": "3"]
        case .ultra: return [
            "farclip": "777", "horizonfarclip": "6226", "unitDrawDist": "300.000000",
            "groundEffectDist": "200", "lodDist": "200", "DistCull": "900.000000",
            "SmallCull": "0.020000", "frillDensity": "32", "specular": "1",
            "pixelShaders": "1", "anisotropic": "16", "shadowlod": "2",
            "weatherDensity": "3", "doodadAnim": "1", "trilinear": "1",
            "Specularity": "1", "SkyCloudLOD": "3"]
        }
    }
}

// ===========================================================================
// 存下来的设置（launcher.json）
//
// 只存启动器自己的选择。音量、UI 缩放这类游戏 cvar 不存这儿 —— 面板打开时
// 从 Config.wtf 现读，不然游戏里改过一次，面板就会把它写回旧值。
// ===========================================================================
struct Settings: Codable {
    var language: Language = .zhCN
    var serverPreset: ServerPreset = .online
    var customServer: String = ""
    var displayMode: DisplayMode = .borderless
    /// "auto" = 跟随显示器，否则形如 "1512x982"
    var resolution: String = "auto"
    /// 0 = 不限制
    var fpsCap: Int = 0
    var quality: QualityPreset = .keep
    /// 游戏开在哪块屏。`Displays.followPanel` = 面板窗口在哪块就用哪块（默认，
    /// 单屏时和「当前主显示器」完全一样）；空 = 当前主显示器，不动排列；
    /// 其余是目标屏的 localizedName —— 存名字不存 ID，显示器 ID 拔插一次就变。
    var preferredDisplay: String = Displays.followPanel
    var retinaMode: Bool = false
    var skipPanel: Bool = false

    var serverAddress: String {
        serverPreset.address ?? customServer.trimmingCharacters(in: .whitespaces)
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Paths.settingsFile, options: .atomic)
    }
}

// ===========================================================================
// Config.wtf
//
// 逐行保留：这文件是客户端自己写的，里面有一堆启动器不认识的键
// （摄像机位置、最后登录的角色…），只能改我们要改的那几行。
// ===========================================================================
struct ConfigWTF {
    private var lines: [String]

    init(_ url: URL) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    private static func key(of line: String) -> String? {
        guard line.hasPrefix("SET ") else { return nil }
        let rest = line.dropFirst(4)
        guard let sp = rest.firstIndex(of: " ") else { return nil }
        return String(rest[rest.startIndex..<sp])
    }

    func value(_ k: String) -> String? {
        for line in lines where Self.key(of: line) == k {
            let parts = line.components(separatedBy: "\"")
            if parts.count >= 2 { return parts[1] }
        }
        return nil
    }

    func double(_ k: String, _ fallback: Double) -> Double {
        guard let v = value(k), let d = Double(v) else { return fallback }
        return d
    }

    mutating func set(_ k: String, _ v: String) {
        let newLine = "SET \(k) \"\(v)\""
        for i in lines.indices where Self.key(of: lines[i]) == k {
            lines[i] = newLine
            return
        }
        // 末尾可能有个空行，插在它前面，别让文件长出一串空行
        if let last = lines.last, last.isEmpty {
            lines.insert(newLine, at: lines.count - 1)
        } else {
            lines.append(newLine)
        }
    }

    mutating func set(_ pairs: [String: String]) {
        for (k, v) in pairs.sorted(by: { $0.key < $1.key }) { set(k, v) }
    }

    /// 先写临时文件再整体换过去，避免半写状态（跟 bin/set-realmlist.sh 一个路子）
    func write(to url: URL) throws {
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
