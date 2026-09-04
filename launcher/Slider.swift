import SwiftUI

// ===========================================================================
// 自己画的滑杆
//
// 为什么不用 SwiftUI 的 Slider：这个 macOS 上滑块**被按住的时候圆钮整个不画**，
// 只剩一条轨道，看着像「透底」。抓帧做过对照实验（ContentView.sliderTest 那个
// 隐藏测试页 + main.swift 的 WOW_SNAPSHOT 钩子）：
//
//   - 最朴素的 Slider，什么修饰都不加 —— 复现
//   - 换成 AppKit 原生 NSSlider —— 一样复现
//   - 加背景、加 compositingGroup、换 controlSize —— 都不影响
//   - 按最右端和按中间都一样，不是被裁掉
//   - 视图 cacheDisplay 和层树 CALayer.render 两种抓法结论一致
//
// 所以是系统层面的，应用侧换控件实现没有出路，只能自己画。
//
// 尺寸和配色是从系统滑杆的截图上逐像素量的（深色模式，2x）：
//   轨道 6pt 高；已填充 #257DFA（就是 accent）；未填充 #343434（底 #1E1E1E）；
//   圆钮 19×16pt 胶囊（不是正圆）、#DDDDDD、下方约 4pt 很淡的阴影。
// 浅色模式下系统圆钮是白的，所以按 colorScheme 换。
// ===========================================================================

struct KnobSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 大于 0 就按这个粒度吸附
    var step: Double = 0

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    private let trackH: CGFloat = 6
    private let knobW: CGFloat = 19
    private let knobH: CGFloat = 16

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - knobW, 1)
            let x = travel * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackH)
                Capsule()
                    .fill(enabled ? Color.accentColor : Color.primary.opacity(0.25))
                    // 填到圆钮中心，跟系统一致：轨道不会从圆钮右边露出来
                    .frame(width: x + knobW / 2, height: trackH)
                Capsule()
                    .fill(scheme == .dark ? Color(white: 0.867) : Color.white)
                    .frame(width: knobW, height: knobH)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.18),
                            radius: 1.2, y: 0.7)
                    .offset(x: x)
            }
            .frame(height: knobH)
            // 整条都是热区：点轨道任意位置直接跳过去，跟系统滑杆一样
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in set(g.location.x, travel) }
            )
        }
        .frame(height: knobH)
        .opacity(enabled ? 1 : 0.5)
        // 自己画的东西默认在无障碍树里是一坨图形，明确声明成可调节元素，
        // VoiceOver 和自动化才认得出来
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { direction in
            let unit = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + unit, range.upperBound)
            case .decrement: value = max(value - unit, range.lowerBound)
            @unknown default: break
            }
        }
    }

    private func set(_ px: CGFloat, _ travel: CGFloat) {
        let t = Double(min(max(px - knobW / 2, 0), travel) / travel)
        var v = range.lowerBound + t * (range.upperBound - range.lowerBound)
        if step > 0 { v = (v / step).rounded() * step }
        value = min(max(v, range.lowerBound), range.upperBound)
    }
}
