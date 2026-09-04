import AppKit
import SwiftUI

// 用户是从哪块屏上双击的图标。只在「下次直接进游戏」那条路上用得着 ——
// 那条路根本不开面板，没有窗口可问。必须在任何窗口出现之前抓。
Displays.captureLaunchDisplay()

// 「下次直接进游戏」：按住 ⌥ 双击才弹面板。
// 游戏已经在跑的时候永远弹面板 —— 直接 exec 会撞上「已经开着了」，
// 用户得看见那句话，而不是一个闪一下就没的图标。
let boot = Settings.load()
if boot.skipPanel,
   !NSEvent.modifierFlags.contains(.option),
   !Launcher.gameIsRunning() {
    let cfg = ConfigWTF(Paths.configWTF(boot.language))
    do {
        let plan = Launcher.plan(boot)
        try Launcher.apply(boot, plan: plan,
                           uiScale: cfg.double("uiScale", 1.0),
                           volumes: Volumes.read(boot.language))
        // plain 那条这一步就 execv 走了，不会回来；
        // 另外两条返回 true，后台线程接着干，这里不能开面板。
        try Launcher.start(boot, plan: plan)
    } catch {
        // 写不进去就老老实实开面板，让人看见哪儿错了
        NSLog("跳过面板启动失败，回到面板：%@", error.localizedDescription)
    }
}

// ---------------------------------------------------------------------------
// 调试钩子：让 app 给自己截图
//
// 进程内截自己的视图（cacheDisplay）不走屏幕录制权限，所以哪怕没给 TCC
// 授权也能拿到真实像素 —— 布局能用 AX 量，渲染只能看像素。
//
//     WOW_SNAPSHOT=/tmp/panel.png WoW.app/Contents/MacOS/WoWLauncher
//     kill -USR1 <pid>        # 收到信号就把当前画面写到那个路径
//
// 用信号而不是定时器，是为了能在「鼠标正按着滑块」那一瞬间抓帧：
// 外面先把鼠标按下去，再发信号。
// ---------------------------------------------------------------------------
private var snapshotPath = ProcessInfo.processInfo.environment["WOW_SNAPSHOT"]
private var snapshotSource: DispatchSourceSignal?

private func armSnapshot(_ window: NSWindow) {
    guard let path = snapshotPath else { return }
    signal(SIGUSR1, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    src.setEventHandler {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSLog("snapshot -> %@", path)
    }
    src.resume()
    snapshotSource = src

    // USR2：走 CALayer.render 而不是 cacheDisplay。
    // cacheDisplay 只画视图自己的 draw()，拖拽中的滑块圆钮是 AppKit 临时
    // 提到别的层里画的，那条路抓不到 —— 层树渲染能不能抓到，用这个对比。
    signal(SIGUSR2, SIG_IGN)
    let src2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    src2.setEventHandler {
        guard let view = window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path + ".layer.png"))
        }
        NSLog("layer snapshot -> %@", path + ".layer.png")
    }
    src2.resume()
    snapshotSource2 = src2
}
private var snapshotSource2: DispatchSourceSignal?

// ---------------------------------------------------------------------------
// 面板开在上次那个地方
//
// 「跟着这个面板走」的判据是面板窗口在哪块屏，而 NSWindow.center() 落在
// NSScreen.main ——「当前有键盘焦点的窗口在哪块屏」，每次开都可能不一样。
// 存一下位置这一项才是稳的：把面板拖到副屏一次，以后每次都开在副屏，
// 游戏也就每次都在副屏全屏。
//
// 没用 AppKit 自带的 setFrameAutosaveName / setFrameUsingName —— 它存的是
// 「窗口原点 + 那块屏的 **visibleFrame**」，而 visibleFrame 里含菜单栏，
// 菜单栏在哪块屏是随前台 App 变的：面板存在内置屏时那块屏是 1512x949，
// 下次启动前如果前台 App 在副屏，内置屏就报 1512x982，对不上，
// setFrameUsingName 直接返回 false，窗口又回去抽签了。实测出来的，不是猜的。
//
// 所以自己存：原点 + 那块屏的 frame。frame 不含菜单栏，不随前台变。
// （另外 setFrameAutosaveName 一调就立刻把当前 frame 存一次，先设名字再读
// 等于读自己刚写进去的值 —— 那条路还有这个坑。）
// ---------------------------------------------------------------------------
enum PanelFrame {
    private static let key = "panelFrame"

    /// "originX originY screenX screenY screenW screenH"
    static func save(_ w: NSWindow) {
        guard let s = w.screen else { return }
        let o = w.frame.origin, f = s.frame
        UserDefaults.standard.set(
            "\(o.x) \(o.y) \(f.origin.x) \(f.origin.y) \(f.width) \(f.height)", forKey: key)
    }

    /// 恢复成功返回 true。没存过、或者那块屏已经不在了就返回 false，让调用方 center()。
    static func restore(_ w: NSWindow) -> Bool {
        guard let text = UserDefaults.standard.string(forKey: key) else { return false }
        let v = text.split(separator: " ").compactMap { Double($0) }
        guard v.count == 6 else { return false }
        let want = CGRect(x: v[2], y: v[3], width: v[4], height: v[5])
        guard let screen = NSScreen.screens.first(where: { $0.frame == want }) else { return false }
        // 夹进可用区：菜单栏和 Dock 可能跟上次不一样，别让标题栏藏到菜单栏后面
        let area = screen.visibleFrame, size = w.frame.size
        w.setFrameOrigin(CGPoint(
            x: min(max(v[0], area.minX), max(area.minX, area.maxX - size.width)),
            y: min(max(v[1], area.minY), max(area.minY, area.maxY - size.height))))
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        // 已经在后台干活了（等窗口出来挪屏、做全屏）—— 不开面板，静静等着
        if waitingForGame { return }

        let host = NSHostingController(rootView: ContentView())
        let w = NSWindow(contentViewController: host)
        w.title = "魔兽世界 1.12.1"
        w.styleMask = [.titled, .closable, .miniaturizable]
        // 窗口和宿主视图都给一层不透明底。（本来是想修「滑块按下去透底」，
        // 后来抓帧证明那跟这个无关 —— 见 ContentView.sliderTest。这两行留着
        // 是因为它本身就该有：面板没有任何需要透出背后内容的地方。）
        w.isOpaque = true
        w.backgroundColor = .windowBackgroundColor
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        w.setContentSize(host.view.fittingSize)
        if !PanelFrame.restore(w) { w.center() }
        w.delegate = self                // 之后用户拖窗口，windowDidMove 里存
        w.makeKeyAndOrderFront(nil)
        // 头一次开（还没存过、走了 center()）也得存下来 —— 上面那句 center()
        // 在 delegate 挂上之前就跑完了，windowDidMove 收不到。
        PanelFrame.save(w)
        window = w
        armSnapshot(w)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidMove(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        PanelFrame.save(w)
    }

    /// 后台干活的时候没有窗口，但不能退 —— 退了就没人给游戏窗口做全屏了
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        !waitingForGame
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(waitingForGame ? .accessory : .regular)
app.run()
