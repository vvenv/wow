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

    /// 按名字找一块屏。显示器 ID 拔插一次就变，名字更耐放。
    static func find(named name: String) -> DisplayInfo? {
        guard !name.isEmpty else { return nil }
        return all().first { $0.name == name }
    }

    /// 「面板在哪块屏」的哨兵值，存进 Settings.preferredDisplay。
    static let followPanel = "@panel"

    /// 面板窗口所在的那块屏。跳过面板那条路上没有窗口，退而求其次用鼠标所在的屏 ——
    /// 用户刚在哪块屏上双击的图标，鼠标就还在哪块屏。
    static func panelDisplay() -> DisplayInfo? {
        let screen = NSApplication.shared.windows.first(where: { $0.isVisible })?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        guard let n = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID else { return main }
        return all().first { $0.id == n } ?? main
    }

    /// 把 Settings.preferredDisplay 解成一块屏。
    /// 空 = 当前主显示器（不动排列）；followPanel = 面板所在那块；否则按名字找。
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
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.id
        }?.backingScaleFactor ?? 1
        return (Int(d.bounds.width * scale), Int(d.bounds.height * scale))
    }

    /// 分辨率候选：目标屏的桌面尺寸 + 常见档位，裁到目标屏之内。
    static func choices(_ display: DisplayInfo?, retina: Bool) -> [String] {
        let limit = desktopSize(display, retina: retina)
        var out = ["\(limit.w)x\(limit.h)"]
        let common = ["1024x768", "1280x720", "1280x800", "1440x900", "1600x900",
                      "1680x1050", "1920x1080", "1920x1200", "2560x1440", "2560x1600",
                      "3024x1964", "3840x2160"]
        for c in common {
            let p = c.split(separator: "x").compactMap { Int($0) }
            if p.count == 2, p[0] <= limit.w, p[1] <= limit.h { out.append(c) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
            .sorted { a, b in
                let pa = a.split(separator: "x").compactMap { Int($0) }
                let pb = b.split(separator: "x").compactMap { Int($0) }
                return pa[0] * pa[1] > pb[0] * pb[1]
            }
    }
}
