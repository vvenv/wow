import SwiftUI
import AppKit

final class Model: ObservableObject {
    @Published var s: Settings
    @Published var uiScale: Double
    @Published var volumes: Volumes
    /// 辅助功能授权。授权是在系统设置里点的，回到面板时刷新一次。
    @Published var axTrusted: Bool = Native.trusted
    /// 服务器延迟（ms）。nil = 正在探测；-1 = 连不上。
    @Published var latencyMs: Double? = nil
    /// 同步页
    @Published var remoteCharCount: String? = nil
    @Published var localCharCount: String? = nil
    @Published var syncing = false
    @Published var syncResult: String? = nil
    @Published var syncForce = false

    private var pingTask: Task<Void, Never>? = nil

    init() {
        var loaded = Settings.load()
        // Retina 是 Wine prefix 里的状态，不是我们存的 —— 以 prefix 为准
        loaded.retinaMode = Launcher.currentRetinaMode()
        s = loaded
        let cfg = ConfigWTF(Paths.configWTF(loaded.language))
        uiScale = cfg.double("uiScale", 1.0)
        volumes = Volumes.read(loaded.language)
        reschedulePing()
        refreshCharCounts()
    }

    /// 换语言就是换客户端目录，UI 缩放和音量得从那一份 Config.wtf 重新读
    func languageChanged() {
        let cfg = ConfigWTF(Paths.configWTF(s.language))
        uiScale = cfg.double("uiScale", 1.0)
        volumes = Volumes.read(s.language)
    }

    func serverChanged() {
        latencyMs = nil
        reschedulePing()
    }

    func refreshCharCounts() {
        Task.detached {
            let local = Self.charCount("local")
            let remote = Self.charCount("remote")
            await MainActor.run {
                self.localCharCount = local
                self.remoteCharCount = remote
            }
        }
    }

    /// 调用 sync-characters.sh status 并解析输出
    private static func charCount(_ which: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Paths.syncScript.path, "status"]
        let env = Paths.toolEnvironment()
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "?" }
        p.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let prefix = which == "local" ? "本地角色数:" : "线上角色数:"
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(prefix) {
                return t.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return "?"
    }

    func reschedulePing() {
        pingTask?.cancel()
        let addr = s.serverAddress
        guard !addr.isEmpty else { latencyMs = nil; return }
        pingTask = Task {
            while !Task.isCancelled {
                let ms = await Pinger.tcpLatency(host: addr, port: 3724)
                if !Task.isCancelled {
                    await MainActor.run { self.latencyMs = ms }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// 屏幕拔插会变，别缓存
    var displays: [DisplayInfo] { Displays.all() }
    var targetDisplay: DisplayInfo? { Displays.resolve(s.preferredDisplay) ?? Displays.main }

    /// 候选只能是主适配器认的档位 —— 客户端建设备时只看那张表，
    /// 列一个选了就掉 800x600 的值比不列更糟。跟目标屏是哪块无关。
    var resolutionChoices: [String] { Displays.choices(retina: s.retinaMode) }

    var autoResolutionLabel: String {
        let d = Displays.desktopSize(Displays.main, retina: s.retinaMode)
        let use = Displays.snap(d.w, d.h, retina: s.retinaMode)
        return "跟随主显示器（\(use.w)x\(use.h)）"
    }

    /// 底栏那句摘要：不翻页也知道这一局会怎么开
    var summary: String {
        let addr = s.serverAddress.isEmpty ? "地址未填" : s.serverAddress
        return "\(s.language.label) · \(s.displayMode.shortLabel) · \(addr)"
    }
}

// ===========================================================================
// 面板
//
// 分页而不是折叠区：折叠区一展开就把内容顶出窗口，Form 自带的滚动视图
// 就冒出滚动条。分页每页高度固定，窗口尺寸自始至终不变，也就没得滚。
// ===========================================================================
struct ContentView: View {
    @StateObject var m = Model()

    /// 所有页共用的高度 = 最高那一页（画面）撑出来的高度。
    /// 写死是故意的：让每一页都不会触发滚动，切页时窗口也不跳。
    ///
    /// 这个数是量出来的，不是拍的：
    ///
    ///     WOW_MEASURE=video WoW.app/Contents/MacOS/WoWLauncher
    ///
    /// 会只画那一页、去掉高度约束，窗口高度减去标题栏（32）就是它的自然高度。
    /// 每页都量一遍，取最大的加一点余量填回这里。往页里加东西了就重新量。
    ///
    /// 上次量的：常规 191、画面 239、声音 189、高级 212、同步 193、位置 225
    /// —— 画面最高（它那行说明是占死两行的）。
    private let pageHeight: CGFloat = 244
    private let pageWidth: CGFloat = 480
    private let measurePage = ProcessInfo.processInfo.environment["WOW_MEASURE"]

    var body: some View {
        if let name = measurePage {
            measured(name)
        } else {
            panel
        }
    }

    @ViewBuilder
    private func measured(_ name: String) -> some View {
        switch name {
        case "general":  general
        case "audio":    audio
        case "advanced": advanced
        case "folders":  folders
        case "sync":     sync
        case "slidertest": sliderTest
        default:        video
        }
    }

    /// 调试用：系统滑杆和自绘滑杆并排，按住任意一条抓帧对比。
    ///
    ///     WOW_MEASURE=slidertest WOW_SNAPSHOT=/tmp/x.png <可执行文件>
    ///     kill -USR1 <pid>        # cacheDisplay
    ///     kill -USR2 <pid>        # CALayer.render
    private var sliderTest: some View {
        VStack(alignment: .leading, spacing: 26) {
            Slider(value: $m.uiScale, in: 0.64...1.0)            // 系统的：按住就丢圆钮
            KnobSlider(value: $m.uiScale, range: 0.64...1.0)     // 自绘的
            HStack(spacing: 8) {
                Image(systemName: "textformat.size").font(.caption).frame(width: 15)
                KnobSlider(value: $m.uiScale, range: 0.64...1.0)
                Text("1.00").font(.callout).monospacedDigit().frame(width: 42)
            }
            KnobSlider(value: $m.uiScale, range: 0.64...1.0).disabled(true)
        }
        .padding(20)
        .frame(width: 480, alignment: .topLeading)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            TabView {
                general.tabItem { Label("常规", systemImage: "gearshape") }
                video.tabItem { Label("画面", systemImage: "display") }
                audio.tabItem { Label("声音", systemImage: "speaker.wave.2") }
                advanced.tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
                sync.tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                folders.tabItem { Label("文件", systemImage: "folder") }
            }
            // 左右 16 跟底栏对齐：分页框的边和摘要文字、按钮在同一条竖线上。
            // 下留 14 是给底栏喘气的 —— 贴着分页框的边看起来像挤在一起。
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)

            footer
        }
        .frame(width: pageWidth + 40)
        // 授权是切到系统设置里点的，切回来时刷新一次 —— 不然得重开面板才看得到
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            m.axTrusted = Native.trusted
        }
    }

    /// 底栏。不要 Divider：分页框自己已经有一圈边框了，再加一条就是两条线挨着。
    private var footer: some View {
        HStack(spacing: 8) {
            emblem
            Text(m.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            latencyBadge
            Spacer(minLength: 8)
            Button("保存") { m.s.save() }
            Button("开始游戏") { start() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // -----------------------------------------------------------------
    private var general: some View {
        page {
            field("语言") {
                Picker("", selection: $m.s.language) {
                    ForEach(Language.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .onChange(of: m.s.language) { _, _ in m.languageChanged() }
            }

            field("服务器") {
                Picker("", selection: $m.s.serverPreset) {
                    ForEach(ServerPreset.available) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .onChange(of: m.s.serverPreset) { _, _ in m.serverChanged() }
            }

            // 常驻但按情况变灰：出现/消失会改变页面高度，那正是滚动条的来源。
            // 选了线上/本地时这里显示那个预设解析出来的地址 —— 弹出菜单只给名字，
            // 地址永远在同一个地方看。
            field("地址") {
                TextField("", text: addressBinding, prompt: Text("例如 192.168.1.10"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .disabled(m.s.serverPreset != .custom)
                    .foregroundStyle(m.s.serverPreset == .custom ? .primary : .secondary)
                    .onChange(of: m.s.customServer) { _, _ in
                        if m.s.serverPreset == .custom { m.serverChanged() }
                    }
            }

            field(nil, note: "勾上以后双击图标就直接起飞。按住 ⌥ 双击回到这个面板。") {
                Toggle("下次直接进游戏", isOn: $m.s.skipPanel)
                    .toggleStyle(.checkbox)
            }
        }
    }

    // -----------------------------------------------------------------
    private var video: some View {
        page {
            field("模式") {
                Picker("", selection: $m.s.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }

            // 说明行数恒定：切换选项时不改页面高度
            field("显示器", note: noteLine,
                  warning: m.s.displayMode == .fullscreen, reserve: true) {
                Picker("", selection: $m.s.preferredDisplay) {
                    Text("跟着这个面板走").tag(Displays.followPanel)
                    Text("当前主显示器").tag("")
                    Divider()
                    ForEach(m.displays) { Text($0.label).tag($0.name) }
                }
                .labelsHidden()
            }

            field("分辨率") {
                Picker("", selection: $m.s.resolution) {
                    Text(m.autoResolutionLabel).tag("auto")
                    Divider()
                    ForEach(m.resolutionChoices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .disabled(!m.s.displayMode.usesResolution)
            }

            field("帧率上限") {
                Picker("", selection: $m.s.fpsCap) {
                    Text("不限制").tag(0)
                    ForEach([60, 90, 120, 144, 165, 240], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .labelsHidden()
            }

            slider("UI 缩放", "textformat.size", $m.uiScale, in: 0.64...1.0) {
                String(format: "%.2f", $0)
            }
        }
    }

    // -----------------------------------------------------------------
    private var advanced: some View {
        page {
            field("画质",
                  note: "「保持不变」一个画质 cvar 都不碰 —— 两个 Config.wtf 都是手调过的，不选预设就不会被覆盖。") {
                Picker("", selection: $m.s.quality) {
                    ForEach(QualityPreset.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }

            field(nil,
                  note: "按真实像素渲染，锐利，但原版 UI 会跟着变小（配合上一页的 UI 缩放）。这是整个 Wine prefix 共享的设置。") {
                Toggle("Wine Retina 模式", isOn: $m.s.retinaMode)
                    .toggleStyle(.checkbox)
            }

            field("原生全屏",
                  note: m.axTrusted
                      ? "游戏会独占一个 Space，也能直接开在副屏，全程不动显示器排列。"
                      : "授权后游戏才能独占 Space、直接开在副屏。授权一次就够，重新编译不会掉。",
                  warning: !m.axTrusted) {
                if m.axTrusted {
                    badge("已授权", "checkmark.seal.fill", .green)
                } else {
                    HStack(spacing: 8) {
                        badge("未授权", "exclamationmark.triangle.fill", .orange)
                        Button("授权辅助功能…") {
                            Native.requestTrust()
                            m.axTrusted = Native.trusted
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    /// 「这次实际会怎么起飞」，不是模式的定义 —— 有没有辅助功能授权走的是
    /// 完全不同的两条路，结果差别很大，得让人看见。
    private var noteLine: String {
        if m.s.displayMode == .fullscreen { return m.s.displayMode.note }
        let onOther = !(m.targetDisplay?.isMain ?? true)
        let name = m.targetDisplay?.name ?? ""
        if m.axTrusted {
            if m.s.displayMode == .borderless {
                return onOther
                    ? "在「\(name)」上开一个独占的 Space，三指滑切换。显示器排列不动。"
                    : "用 macOS 原生全屏，游戏独占一个 Space，三指滑就能切出来。"
            }
            return onOther ? "窗口会被挪到「\(name)」上打开。" : m.s.displayMode.note
        }
        if onOther {
            return "没有辅助功能授权，游戏会在当前主显示器上打开。去「高级」页授权。"
        }
        return m.s.displayMode.note + " 授权后可独占 Space（见「高级」）。"
    }

    // -----------------------------------------------------------------
    private var audio: some View {
        page {
            slider("主音量", "speaker.wave.3.fill", $m.volumes.master, in: 0...1) { pct($0) }
            slider("音乐", "music.note", $m.volumes.music, in: 0...1) { pct($0) }
            slider("音效", "waveform", $m.volumes.sound, in: 0...1) { pct($0) }
            slider("环境", "leaf.fill", $m.volumes.ambience, in: 0...1) { pct($0) }
            // 缩进到控件列：全篇的说明文字都从这条线起，页面之间才对得上
            note("打开面板时这几个值是从当前客户端的 Config.wtf 现读的，你在游戏里调过的音量不会被打回去。")
                .padding(.leading, labelWidth + labelGap)
                .padding(.top, 2)
        }
    }

    // -----------------------------------------------------------------
    private var sync: some View {
        page {
            // 两端角色数并排，中间一个双向箭头 —— 一眼看出两边差多少。
            // 走 field() 是为了跟下面几行共用同一条标签列，别自己歪一边。
            field("角色数", align: .center) {
                HStack(spacing: 10) {
                    counter("线上", m.remoteCharCount)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    counter("本地", m.localCharCount)
                    Button {
                        m.refreshCharCounts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(m.syncing)
                    .help("重新读两端的角色数")
                    .padding(.leading, 2)
                }
            }

            // 选项在按钮**上面**：它是动作的修饰语，不是结果。摆在下面的话，
            // 人是先看到按钮、点下去，才发现刚才有个开关改了刚刚发生的事 ——
            // 何况这是整库覆盖，影响安全的开关必须出现在扣扳机之前。
            field(nil) {
                Toggle("直接覆盖（跳过备份）", isOn: $m.syncForce)
                    .toggleStyle(.checkbox)
                    .disabled(m.syncing)
            }

            field(nil) {
                HStack(spacing: 8) {
                    Button {
                        runSync("pull")
                    } label: {
                        Label("线上 → 本地", systemImage: "arrow.down.circle")
                    }
                    .disabled(m.syncing)
                    Button {
                        runSync("push")
                    } label: {
                        Label("本地 → 线上", systemImage: "arrow.up.circle")
                    }
                    .disabled(m.syncing)
                }
            }

            // 高度恒定的状态区：转圈和结果都落在这儿，页面不会跳
            HStack(alignment: .top, spacing: 6) {
                if m.syncing {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                }
                note(syncNote,
                     warning: m.syncResult?.contains("失败") == true || (m.syncForce && !m.syncing),
                     reserve: true)
            }
            .padding(.leading, labelWidth + labelGap)
        }
    }

    /// 状态行。勾了「直接覆盖」就得说清楚代价 —— 这一步没有回头路。
    private var syncNote: String {
        if m.syncing { return "正在同步，别关面板。" }
        if let r = m.syncResult { return r }
        return m.syncForce
            ? "⚠️ 不备份，目标端整库直接被覆盖，覆盖掉的角色找不回来。"
            : "先把目标端备份到 downloads/db-sync/，再整库覆盖。"
    }

    private func runSync(_ direction: String) {
        m.syncing = true
        m.syncResult = nil
        let script = Paths.syncScript.path
        let force = m.syncForce
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            var args = [script, direction]
            if force { args.append("--force") }
            p.arguments = args
            p.environment = Paths.toolEnvironment()
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let ok = p.terminationStatus == 0
                let tail = output.split(separator: "\n", omittingEmptySubsequences: false)
                    .suffix(2).joined(separator: " ")
                await MainActor.run {
                    m.syncResult = ok ? "同步完成。" : "同步失败：\(tail)"
                    m.syncing = false
                    m.refreshCharCounts()
                }
            } catch {
                await MainActor.run {
                    m.syncResult = "启动失败：\(error.localizedDescription)"
                    m.syncing = false
                }
            }
        }
    }

    // -----------------------------------------------------------------
    private var folders: some View {
        page {
            // 这一页没有「设置」，全是去 Finder 的入口 —— 做成一格一格的卡片
            // 比五行「标签 + 打开按钮」扫得快，整张卡都是热区。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      spacing: 10) {
                folderCard("日志", "doc.text", Paths.logFile(m.s.language))
                folderCard("客户端", "gamecontroller", Paths.clientDir(m.s.language))
                folderCard("插件", "puzzlepiece.extension", Paths.addonsDir)
                folderCard("WTF", "slider.horizontal.3",
                           Paths.clientDir(m.s.language).appendingPathComponent("WTF"))
                folderCard("截图", "photo", Paths.clientDir(m.s.language)
                           .appendingPathComponent("Screenshots"))
            }
            note("启动不了先看日志。灰掉的是还没生成的那几个。")
                .padding(.top, 2)
        }
    }

    // -----------------------------------------------------------------
    // 零件
    // -----------------------------------------------------------------

    /// 标签列宽度。所有页共用一个数，控件列的起点才会在切页时纹丝不动 ——
    /// 交给 Form 自动算的话每页按最长标签各算各的，切一次页控件就横向跳一下。
    private let labelWidth: CGFloat = 62
    private let labelGap: CGFloat = 10
    /// 字段之间的呼吸。挨着排是「表单项没有间隔」的由来。
    private let fieldGap: CGFloat = 13

    /// 每一页统一的容器。
    ///
    /// 不用 Form：它在 macOS 上是个两列 Grid，行距由系统定死、说明文字会被塞进
    /// 右边那列拿到「单行理想宽度」的提议，长句要么顶出边框要么从中间折断。
    /// 自己摆行之后间距、标签列宽、说明的折行宽度全都拿得住。
    ///
    /// 高度写死，多出来的地方留白，结构上就没有可滚的东西 —— 没有 ScrollView
    /// 也就没有滚动条，切页时窗口尺寸也不跳。
    private func page<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: fieldGap) {
            content()
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: pageWidth, height: measurePage == nil ? pageHeight : nil, alignment: .topLeading)
    }

    /// 一个设置项：左边右对齐的标签，右边控件，下面可选一行说明。
    /// 说明缩进到控件列 —— 跟 macOS 系统设置一个路数，读起来是一组。
    /// label 传 nil = 不要标签，但仍占住标签列的宽度 —— 复选框、自解释的按钮
    /// 这类控件本身就带文字，再给一个「选项」「启动」纯属重复；空着但对齐，
    /// 视觉上还是同一条竖线。
    private func field<C: View>(_ label: String?, note text: String? = nil,
                                warning: Bool = false, reserve: Bool = false,
                                align: VerticalAlignment = .firstTextBaseline,
                                @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: align, spacing: labelGap) {
                Text(label ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .trailing)
                control()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let text {
                note(text, warning: warning, reserve: reserve)
                    .padding(.leading, labelWidth + labelGap)
            }
        }
    }

    /// 说明文字。宽度上限按量出来的页内容宽给，让它折在末尾而不是半中间。
    /// reserve 只给会随选项变化的那几处：占死两行，切换时页面高度不动。
    private func note(_ text: String, warning: Bool = false, reserve: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .lineLimit(2, reservesSpace: reserve)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // width 而不是 maxWidth：maxWidth 下 Text 仍按「单行理想宽度」收窄，
            // 结果是没用满就折了。给定宽才会一直排到右边再折。
            .frame(width: pageWidth - 32 - labelWidth - labelGap, alignment: .leading)
    }

    /// 状态徽章。比一行灰字有分量，一眼能扫到。
    private func badge(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }

    /// 同步页那两个计数
    private func counter(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value ?? "—")
                .font(.title3.monospacedDigit().weight(.medium))
        }
        .frame(minWidth: 52, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    /// 滑杆前面那个小图标是 macOS 声音设置的路数：一眼分清哪条是哪条，
    /// 比四行只有文字标签好扫。双列试过 —— 448pt 宽分两列后每条滑杆只剩
    /// 100pt 行程，调音量太粗，不值得。
    private func slider(_ title: String, _ symbol: String, _ value: Binding<Double>,
                        in range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        field(title) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 15)
                KnobSlider(value: value, range: range)
                Text(format(value.wrappedValue))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private func folderCard(_ title: String, _ symbol: String, _ url: URL) -> some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        return Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            VStack(spacing: 5) {
                // 图标占死一个高度：SF Symbol 各自的字形高度不一样，
                // 不锁住的话同一行的卡片会高低不齐（实测差了 3.5pt）
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(height: 20)
                    .foregroundStyle(exists ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(.tertiary))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(exists ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(exists ? 0.05 : 0.025),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .help(url.path)
    }

    /// 底栏那枚徽章。就是图标的源图（256px 圆形，四角透明），
    /// build.sh 会把它拷进 Resources。
    @ViewBuilder
    private var emblem: some View {
        if let url = Bundle.main.url(forResource: "emblem", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
        }
    }

    /// 地址框：自定义时可写，选了预设就只读地显示那个预设的地址。
    private var addressBinding: Binding<String> {
        Binding(
            get: {
                m.s.serverPreset == .custom ? m.s.customServer
                                            : (m.s.serverPreset.address ?? "")
            },
            set: { new in
                if m.s.serverPreset == .custom { m.s.customServer = new }
            }
        )
    }

    // -----------------------------------------------------------------
    /// 底栏延迟徽章
    @ViewBuilder
    private var latencyBadge: some View {
        if let ms = m.latencyMs {
            if ms < 0 {
                badge("超时", "bolt.horizontal.circle.fill", .red)
            } else {
                badge(ms < 1 ? "<1 ms" : "\(Int(ms)) ms", "wifi",
                      ms < 80 ? .green : ms < 200 ? .orange : .red)
            }
        } else {
            badge("探测中", "wifi", .gray)
        }
    }

    // -----------------------------------------------------------------
    private func start() {
        m.s.save()
        do {
            if Launcher.gameIsRunning() { throw LaunchError.alreadyRunning }
            if m.s.retinaMode != Launcher.currentRetinaMode() {
                Launcher.setRetinaMode(m.s.retinaMode)
            }
            // 同一份 plan 给 apply 和 start —— 走哪条路决定了写进 Config.wtf
            // 的窗口 cvar，两边各算一次就可能不一致
            let plan = Launcher.plan(m.s)
            try Launcher.apply(m.s, plan: plan, uiScale: m.uiScale, volumes: m.volumes)
            // plain 那条直接 execv 走了；另外两条会返回，后台线程接着干，
            // 面板已经自己收起来了
            try Launcher.start(m.s, plan: plan)
        } catch {
            let a = NSAlert()
            a.messageText = "启动不了"
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            a.runModal()
        }
    }
}
