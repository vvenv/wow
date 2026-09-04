import AppKit

// ===========================================================================
// 显示器
//
// 1.12 的客户端没法被告知用哪块屏 —— 完整的 cvar 表里只有 gxWindow /
// gxMaximize / gxResolution，没有 gxMonitor（那是 WotLK 才加的）。客户端调
// MonitorFromRect，也就是「窗口落在哪块屏，就在哪块屏最大化」，而 Wine 把
// 窗口摆在桌面原点，原点永远是主显示器。
//
// Wine 的虚拟桌面（explorer /desktop=）本来是另一条路，但 WoWSilicon 这个
// Wine 里 explorer.exe 自己就崩，走不通。
//
// 解法在 Native.swift：客户端开出来的是个普通 Cocoa 窗口，辅助功能 API
// 能把它挪到任意一块屏，再交给 macOS 变原生全屏。这里只负责枚举显示器
// 和算尺寸。
// ===========================================================================

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let bounds: CGRect          // CoreGraphics 坐标：左上角原点
    let refresh: Int

    var isMain: Bool { bounds.origin == .zero }
    var pixelSize: String { "\(Int(bounds.width))x\(Int(bounds.height))" }
    var label: String { "\(name)（\(pixelSize)）" }
}

enum Displays {

    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        // localizedName 只有 NSScreen 有，按 NSScreenNumber 对回去
        var names: [CGDirectDisplayID: String] = [:]
        var rates: [CGDirectDisplayID: Int] = [:]
        for s in NSScreen.screens {
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { continue }
            names[n] = s.localizedName
            rates[n] = s.maximumFramesPerSecond
        }

        return ids.map { id in
            DisplayInfo(id: id,
                        name: names[id] ?? "显示器 \(id)",
                        bounds: CGDisplayBounds(id),
                        refresh: rates[id] ?? 60)
        }
        .sorted { a, b in a.isMain && !b.isMain }   // 主屏排最前
    }

    static var main: DisplayInfo? { all().first(where: \.isMain) }

    static func screen(of id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
    }

    /// 按名字找一块屏。显示器 ID 拔插一次就变，名字更耐放。
    static func find(named name: String) -> DisplayInfo? {
        guard !name.isEmpty else { return nil }
        return all().first { $0.name == name }
    }

    // -----------------------------------------------------------------
    // 「跟着这个面板走」
    //
    // 判据就是面板窗口此刻压在哪块屏上 —— 想换屏就把面板拖过去再点开始游戏。
    // 眼睛看得见，不用猜。
    //
    // 勾了「下次直接进游戏」那条路上根本没有面板，没有窗口可问，这时候才退回
    // 「启动那一刻鼠标在哪块屏」= 用户双击图标的那块屏。它必须在任何窗口出现
    // 之前抓：面板一摆出来，NSEvent.mouseLocation 就跟着用户去点按钮了。
    // -----------------------------------------------------------------
    private static var launched: CGDirectDisplayID?

    /// 只在 main.swift 最开头调用一次，且必须早于任何窗口出现。
    static func captureLaunchDisplay() {
        let p = NSEvent.mouseLocation
        let s = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        launched = s?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 「面板在哪块屏」的哨兵值，存进 Settings.preferredDisplay。
    static let followPanel = "@panel"

    /// 面板窗口所在的那块屏。
    ///
    /// 用 NSApplication.shared 而不是 NSApp：跳过面板那条路上 AppKit 还没起来，
    /// NSApp 是 nil，碰一下就崩（踩过）。keyWindow / mainWindow 优先于「第一个
    /// 可见窗口」—— 面板是唯一的窗口，但顺序不该靠运气。
    static func panelDisplay() -> DisplayInfo? {
        let app = NSApplication.shared
        let panel = app.keyWindow?.screen ?? app.mainWindow?.screen
            ?? app.windows.first(where: { $0.isVisible })?.screen
        if let n = panel?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID, let d = all().first(where: { $0.id == n }) { return d }
        // 没有面板（跳过面板那条路）—— 用启动那一刻鼠标所在的屏
        if let id = launched, let d = all().first(where: { $0.id == id }) { return d }
        return main
    }

    /// 把 Settings.preferredDisplay 解成一块屏。
    /// 空 = 当前主显示器（不动排列）；followPanel = 启动时鼠标所在那块；否则按名字找。
    static func resolve(_ pref: String) -> DisplayInfo? {
        if pref == followPanel { return panelDisplay() }
        return find(named: pref)
    }

    /// Wine 看到的桌面尺寸。Mac driver 默认不开 Retina 模式，按「点」算，
    /// 也就是 NSScreen.frame 而不是背后的像素数。
    static func desktopSize(_ display: DisplayInfo?, retina: Bool) -> (w: Int, h: Int) {
        let d = display ?? main
        guard let d else { return (1920, 1080) }
        guard retina else { return (Int(d.bounds.width), Int(d.bounds.height)) }
        let scale = screen(of: d.id)?.backingScaleFactor ?? 1
        return (Int(d.bounds.width * scale), Int(d.bounds.height * scale))
    }

    // -----------------------------------------------------------------
    // 主适配器的模式表
    //
    // 客户端建 D3D 设备时只认**主显示器**那张模式表（D3D adapter 0）。
    // gxResolution 不在表里就直接掉回 800x600 —— 实测：
    //
    //     1512x850   放得进桌面，但不在表里 → Buffer size: 800x600
    //     1512x945   在表里                 → Buffer size: 1512x945
    //
    // 副屏的原生分辨率几乎注定不在主屏这张表里（这台机器上内置屏一个 16:9
    // 的档位都没有），所以「按目标屏尺寸写 gxResolution」必然翻车。
    //
    // 好在跑起来的尺寸不靠 gxResolution：客户端跟着窗口大小 Reset
    // （同一次实测里 1512x945 的窗口被 Cocoa 压到 917，它立刻 Reset 了一次）。
    // 进原生全屏之后它自己就会变成目标屏的尺寸，一比一，不拉伸。
    // 所以这里只要给一个「开得出来」的合法值就够了。
    //
    // Wine 的 Mac driver 也是从 CGDisplayCopyAllDisplayModes 取的模式，
    // RetinaMode 关着按「点」报，开着按像素报 —— 跟这里一致。
    // -----------------------------------------------------------------
    static func primaryModes(retina: Bool) -> [(w: Int, h: Int)] {
        guard let id = main?.id else { return [] }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return [] }
        var seen = Set<Int>()
        var out: [(w: Int, h: Int)] = []
        for m in modes {
            let w = retina ? m.pixelWidth : m.width
            let h = retina ? m.pixelHeight : m.height
            guard w > 0, h > 0, seen.insert(w << 16 | h).inserted else { continue }
            out.append((w, h))
        }
        return out.sorted { $0.w * $0.h > $1.w * $1.h }
    }

    /// 把任意一个想要的尺寸夹到模式表里 —— 取「不超过它的最大那档」。
    /// 表是空的（拿不到模式）就原样放行，总比硬塞一个 800x600 强。
    static func snap(_ w: Int, _ h: Int, retina: Bool) -> (w: Int, h: Int) {
        let modes = primaryModes(retina: retina)
        guard !modes.isEmpty else { return (w, h) }
        return modes.first { $0.w <= w && $0.h <= h } ?? modes[modes.count - 1]
    }

    /// 走原生全屏那条路时，起飞用的窗口尺寸。
    ///
    /// 这个窗口是过渡态，一秒后就被 macOS 变成目标屏的全屏了，所以不用管
    /// 宽高比，只要两件事：在模式表里（不然 800x600），以及放得进主屏的
    /// 可用区（不然 Cocoa 会把它压小，客户端白 Reset 一次）。
    static func safeWindowSize(retina: Bool) -> (w: Int, h: Int) {
        let modes = primaryModes(retina: retina)
        guard let d = main, !modes.isEmpty else { return (1024, 768) }
        let scale = retina ? (screen(of: d.id)?.backingScaleFactor ?? 1) : 1
        // 可用区还要再扣掉标题栏 —— 游戏窗口是带标题栏的普通窗口
        let visible = screen(of: d.id)?.visibleFrame.size ?? d.bounds.size
        let chrome = NSWindow.frameRect(forContentRect: .zero,
                                        styleMask: [.titled, .closable, .miniaturizable]).height
        let limitW = visible.width * scale
        let limitH = (visible.height - chrome) * scale
        return modes.first { CGFloat($0.w) <= limitW && CGFloat($0.h) <= limitH }
            ?? modes[modes.count - 1]
    }

    /// 分辨率候选。只列主适配器认的档位 —— 列一个选了就掉 800x600 的值
    /// 比不列更糟。副屏尺寸不在这儿出现是对的：客户端根本开不出来。
    static func choices(retina: Bool) -> [String] {
        primaryModes(retina: retina).map { "\($0.w)x\($0.h)" }
    }
}
