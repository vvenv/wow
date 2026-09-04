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
//      写的是窗口 cvar + 目标屏的完整尺寸，视觉结果一样。
//   2. 需要辅助功能授权。没授权就只能老实在当前主屏开，面板会说清楚。
//
// 尺寸要在起飞前就写成目标屏的桌面尺寸：这样进全屏时内容区尺寸不变，
// 客户端不用重建交换链，也就不会被 DXVK 拉伸糊掉。
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

    /// 某个进程的游戏窗口。判据是**全屏按钮**而不是标题或尺寸 —— wine 同时开着
    /// 好几个窗口（菜单栏那条 1512x33、几个隐藏的 500x500），只有真正的游戏窗口
    /// 有这个按钮。
    private static func window(of pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                            kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        for w in windows {
            var button: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXFullScreenButtonAttribute as CFString,
                                             &button) == .success {
                return w
            }
        }
        return nil
    }

    /// 等游戏窗口出现（最多 timeout 秒）。起 Wine + 编译着色器可能要十几秒。
    ///
    /// ⚠️ **wine 不在前台的时候，AX 的 kAXWindows 返回空数组** —— 不是报错，
    /// 就是干干净净的 0 个窗口，查不出任何毛病。启动器起完游戏就把面板收了、
    /// 切成 accessory，游戏那个 app 从来没被激活过，于是这里永远等不到窗口。
    /// 所以必须主动 activate 它一下。反正玩家本来就要游戏在前台，不算副作用。
    private static func waitForWindow(_ timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for pid in winePIDs() {
                guard let running = NSRunningApplication(processIdentifier: pid),
                      running.activationPolicy == .regular else { continue }
                if let w = window(of: pid) { return w }
                // 空数组多半就是「没在前台」，推它一把再看
                running.activate()
                Thread.sleep(forTimeInterval: 0.6)
                if let w = window(of: pid) { return w }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// 把游戏窗口挪到目标屏，需要的话再进原生全屏。
    ///
    /// 返回是否全都做成了。做不成也不影响游戏本身 —— 它已经在跑了，
    /// 只是留在原来那块屏上而已，所以调用方不用把这当成致命错误。
    @discardableResult
    static func place(on target: DisplayInfo?, fullscreen: Bool,
                      timeout: TimeInterval = 120) -> Bool {
        guard trusted, let win = waitForWindow(timeout) else { return false }

        // AXPosition 用的是左上角原点的全局坐标，和 CGDisplayBounds 一套。
        if let t = target, !t.isMain {
            var origin = t.bounds.origin
            if let v = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
                // Wine 那边处理 WM_MOVE 要一会儿，不等一下接着全屏会落回原来那块屏
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        guard fullscreen else { return true }

        // 设完回读确认。AXUIElementSetAttributeValue 返回 .success 只代表消息送到了，
        // 不代表窗口真进了全屏 —— 游戏刚起来那几秒 Wine 那边还在忙，会吃掉这一下。
        for _ in 0..<4 {
            AXUIElementSetAttributeValue(win, fullScreenAttr, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 1.2)
            var now: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, fullScreenAttr, &now) == .success,
               (now as? Bool) == true {
                return true
            }
        }
        return false
    }
}
