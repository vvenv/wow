import AppKit
import SwiftUI

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

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        armSnapshot(w)
        NSApp.activate(ignoringOtherApps: true)
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
