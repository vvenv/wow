import AppKit
import ApplicationServices

// ===========================================================================
// 原生全屏
//
// 客户端自己没法被告知用哪块屏（1.12 没有 gxMonitor），但它开出来的是一个
// 普通 Cocoa 窗口 —— 辅助功能 API 能挪（AXPosition）、能全屏（AXFullScreen），
// 而 macOS 的原生全屏本来就会给窗口开一个专属 Space。
//
// 等于把「新建一个桌面」这件事白拿了：显示器排列一点都不用碰，菜单栏和 Dock
// 不搬家，游戏自带一个 Space，三指滑就能切进切出。
//
// 两个硬前提：
//
//   1. 必须窗口模式。Wine 的 adjustFullScreenBehavior: 明确排除 maximized
//      的窗口，gxMaximize=1 根本拿不到全屏按钮。所以「无边框满屏」走这条路时
//      写的是窗口 cvar + 一个开得出来的尺寸，视觉结果一样。
//   2. 需要辅助功能授权。没授权就只能老实在当前主屏开，面板会说清楚。
//
// 起飞尺寸不需要等于目标屏：客户端会跟着窗口大小 Reset，进全屏之后自己就
// 变成目标屏的尺寸了（实测见 Displays.primaryModes 上面那段）。
// ===========================================================================

enum Native {

    /// AXFullScreen 没有公开常量，只能用字符串
    private static let fullScreenAttr = "AXFullScreen" as CFString

    static var trusted: Bool { AXIsProcessTrusted() }

    /// 弹一次系统的辅助功能授权对话框。只在用户真的选了需要它的选项时才弹，
    /// 别一开面板就骚扰人。
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // -----------------------------------------------------------------
    // 读窗口的几何
    // -----------------------------------------------------------------

    private static func axValue(_ win: AXUIElement, _ attr: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, attr as CFString, &raw) == .success,
              let v = raw, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    private static func position(_ win: AXUIElement) -> CGPoint? {
        guard let v = axValue(win, kAXPositionAttribute as String) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    private static func size(_ win: AXUIElement) -> CGSize? {
        guard let v = axValue(win, kAXSizeAttribute as String) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    /// 窗口现在主要压在哪块屏上。AXPosition/AXSize 用的是左上角原点的全局坐标，
    /// 和 CGDisplayBounds 一套，直接求交集面积就行。
    private static func screenOf(_ win: AXUIElement) -> CGDirectDisplayID? {
        guard let p = position(win), let s = size(win) else { return nil }
        let frame = CGRect(origin: p, size: s)
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for d in Displays.all() {
            let hit = d.bounds.intersection(frame)
            let area = hit.isNull ? 0 : hit.width * hit.height
            if area > (best?.area ?? 0) { best = (d.id, area) }
        }
        return best?.id
    }

    // -----------------------------------------------------------------
    // 找窗口
    // -----------------------------------------------------------------

    /// 开着窗口的那些 wine 进程。CGWindowList 不受 Space 影响，也不要求对方在前台，
    /// 所以先用它筛出候选，再去问 AX。
    private static func winePIDs() -> [pid_t] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var pids: [pid_t] = []
        for w in list {
            guard (w["kCGWindowLayer"] as? Int) == 0,
                  let owner = w["kCGWindowOwnerName"] as? String,
                  owner.lowercased().contains("wine"),
                  let pid = w["kCGWindowOwnerPID"] as? pid_t,
                  !pids.contains(pid)
            else { continue }
            pids.append(pid)
        }
        return pids
    }

    /// 某个进程的游戏窗口。判据是**尺寸** —— wine 同时开着好几个窗口
    /// （副屏那条菜单栏 1920x32、主屏那条 1512x33、几个隐藏的 500x500），
    /// 游戏本体是里面最大的，一条 640x480 的下限就把杂鱼全挡掉了。
    /// kAXWindows 的顺序是 z-order，取第一个等于抽签，抽中杂鱼就会去挪它、
    /// 给它全屏，游戏本体留在主屏上不动。
    ///
    /// `needsFullScreenButton` 只有走 macOS 原生全屏时才该开：没有
    /// kAXFullScreenButtonAttribute 的窗口 AXFullScreen 设不动。
    /// ⚠️ 但**无边框最大化**（gxMaximize=1）的窗口就是没有这个按钮的
    /// —— Wine 的 adjustFullScreenBehavior: 明确排除 maximized 的窗口。
    /// 所以 coverScreen 那条路上必须关掉这道判据，否则一个窗口都找不到，
    /// place() 直接返回 false，游戏原地不动（踩过）。
    private static func window(of pid: pid_t, needsFullScreenButton: Bool) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                            kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        var best: (win: AXUIElement, area: CGFloat)?
        for w in windows {
            guard let s = size(w), s.width >= 640, s.height >= 480 else { continue }
            if needsFullScreenButton {
                var button: CFTypeRef?
                guard AXUIElementCopyAttributeValue(w, kAXFullScreenButtonAttribute as CFString,
                                                    &button) == .success else { continue }
            }
            let area = s.width * s.height
            if area > (best?.area ?? 0) { best = (w, area) }
        }
        return best?.win
    }

    /// 等游戏窗口出现（最多 timeout 秒）。起 Wine + 编译着色器可能要十几秒。
    ///
    /// ⚠️ **wine 不在前台的时候，AX 的 kAXWindows 返回空数组** —— 不是报错，
    /// 就是干干净净的 0 个窗口，查不出任何毛病。启动器起完游戏就把面板收了、
    /// 切成 accessory，游戏那个 app 从来没被激活过，于是这里永远等不到窗口。
    /// 所以必须主动 activate 它一下。反正玩家本来就要游戏在前台，不算副作用。
    private static func waitForWindow(_ timeout: TimeInterval,
                                      needsFullScreenButton: Bool) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for pid in winePIDs() {
                guard let running = NSRunningApplication(processIdentifier: pid),
                      running.activationPolicy == .regular else { continue }
                if let w = window(of: pid, needsFullScreenButton: needsFullScreenButton) { return w }
                // 空数组多半就是「没在前台」，推它一把再看
                running.activate()
                Thread.sleep(forTimeInterval: 0.6)
                if let w = window(of: pid, needsFullScreenButton: needsFullScreenButton) { return w }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    // -----------------------------------------------------------------
    // 挪 + 全屏
    // -----------------------------------------------------------------

    /// 把窗口挪到目标屏正中，回读确认真的过去了。
    ///
    /// 原来是「设一次 AXPosition，睡 0.5 秒，接着全屏」。那 0.5 秒是猜的：
    /// Wine 处理 WM_MOVE 要多久没有定数，而副屏在负坐标区时（这台机器上副屏
    /// 原点是 -210,-1080）macdrv 还会把窗口往主屏拽回去。猜错了下一步就在
    /// 主屏上全屏了，而且原来的代码从不回读，错了也不知道。
    ///
    /// 目标点取屏幕正中而不是左上角：贴着原点摆会被菜单栏往下顶，
    /// 而且窗口比屏幕高一点的时候还会有一截挂到隔壁屏上去。
    /// ⚠️ 重试预算要给够。这里是从「AX 第一次能看见窗口」那一刻就开始试的，
    /// 而那会儿 Wine 还在忙（着色器、GC、登录界面资源），设进去的位置会被整批吃掉。
    /// 一开始给的是 12×0.3s ≈ 3.6 秒，实测会整局放弃、窗口原地不动 —— 20 秒才够。
    private static func move(_ win: AXUIElement, to target: DisplayInfo) -> Bool {
        for _ in 0..<40 {
            if screenOf(win) == target.id { return true }
            let s = size(win) ?? CGSize(width: target.bounds.width, height: target.bounds.height)
            var origin = CGPoint(
                x: max(target.bounds.minX, target.bounds.midX - s.width / 2),
                y: max(target.bounds.minY, target.bounds.midY - s.height / 2))
            if let v = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return screenOf(win) == target.id
    }

    /// 把窗口拉到正好盖住整块目标屏。设完回读确认，Wine 那边可能吃掉一次。
    ///
    /// 先摆位置再定尺寸，然后把位置再压一遍 —— 在旧位置上直接放大，
    /// Cocoa 会按旧那块屏来约束尺寸。
    private static func cover(_ win: AXUIElement, _ t: DisplayInfo) -> Bool {
        func set(_ attr: String, _ value: AXValue?) {
            guard let v = value else { return }
            AXUIElementSetAttributeValue(win, attr as CFString, v)
        }
        for _ in 0..<20 {
            var origin = t.bounds.origin
            var wanted = t.bounds.size
            set(kAXPositionAttribute as String, AXValueCreate(.cgPoint, &origin))
            set(kAXSizeAttribute as String, AXValueCreate(.cgSize, &wanted))
            set(kAXPositionAttribute as String, AXValueCreate(.cgPoint, &origin))
            Thread.sleep(forTimeInterval: 0.5)
            if let p = position(win), let s = size(win),
               abs(p.x - t.bounds.minX) < 2, abs(p.y - t.bounds.minY) < 2,
               abs(s.width - t.bounds.width) < 2, abs(s.height - t.bounds.height) < 2 {
                return true
            }
        }
        return false
    }

    /// 把游戏窗口挪到目标屏，再按 fill 摆成满屏。
    ///
    /// 返回是否全都做成了。做不成也不影响游戏本身 —— 它已经在跑了，
    /// 只是留在原来那块屏上而已，所以调用方不用把这当成致命错误。
    @discardableResult
    static func place(on target: DisplayInfo?, fill: FillMode,
                      timeout: TimeInterval = 120) -> Bool {
        guard trusted,
              let win = waitForWindow(timeout, needsFullScreenButton: fill == .nativeFullScreen)
        else { return false }

        let needsMove = !(target?.isMain ?? true)
        if needsMove, let t = target, !move(win, to: t) {
            // 挪不过去就别接着摆了：在错的屏上满屏比留在原屏当个窗口更难受
            return false
        }

        switch fill {
        case .none:
            return true

        case .coverScreen:
            guard let t = target ?? Displays.main else { return false }
            return cover(win, t)

        case .nativeFullScreen:
            break
        }

        for _ in 0..<4 {
            // 每一轮开始前重新确认落位 —— 上一轮的退出全屏可能把它甩回主屏
            if needsMove, let t = target, screenOf(win) != t.id, !move(win, to: t) { continue }

            AXUIElementSetAttributeValue(win, fullScreenAttr, kCFBooleanTrue)
            // 设完回读确认。AXUIElementSetAttributeValue 返回 .success 只代表消息送到了，
            // 不代表窗口真进了全屏 —— 游戏刚起来那几秒 Wine 那边还在忙，会吃掉这一下。
            // 全屏动画本身也要大半秒，太早读到的还是旧位置。
            Thread.sleep(forTimeInterval: 1.2)

            var now: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, fullScreenAttr, &now) == .success,
                  (now as? Bool) == true
            else { continue }

            // 全屏了 —— 但得是在**对的那块屏**上。原来这里只看这个布尔值，
            // 于是一旦在主屏上全屏成功就立刻返回 true 收工，正是「有时候全屏
            // 跑到主屏来」那个症状里最后一道没拦住的关。
            if let t = target, screenOf(win) != t.id {
                AXUIElementSetAttributeValue(win, fullScreenAttr, kCFBooleanFalse)
                Thread.sleep(forTimeInterval: 1.2)
                continue
            }
            return true
        }
        return false
    }
}
