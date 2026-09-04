import AppKit
import SwiftUI
import CoreImage

// ===========================================================================
// 生成 launcher/wow.icns
//
// 原来的图标只有一张 256x256，而且是满幅方图：Dock 里既糊（Retina 要 1024）
// 又不是 macOS 的圆角方形，跟旁边的图标不是一套。
//
// 这里把那枚徽章（emblem.png，圆形，四角透明）摆到一块标准比例的 squircle
// 底板上，再按 Apple 的尺寸阶梯整套渲染出来。底板和描边是矢量的，每个尺寸
// 单独渲染，所以小图不是大图缩出来的糊边。
// ===========================================================================

let srcDir = URL(fileURLWithPath: CommandLine.arguments[1])
let outIcns = URL(fileURLWithPath: CommandLine.arguments[2])

guard let emblemRaw = NSImage(contentsOf: srcDir.appendingPathComponent("emblem.png")) else {
    fputs("读不到 emblem.png\n", stderr); exit(1)
}

/// 先用 Lanczos 把 256 的徽章放到 660 —— 比交给绘图层的双线性插值干净。
func lanczos(_ image: NSImage, to side: CGFloat) -> NSImage {
    guard let tiff = image.tiffRepresentation,
          let ci = CIImage(data: tiff) else { return image }
    let scale = side / ci.extent.width
    guard let f = CIFilter(name: "CILanczosScaleTransform") else { return image }
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(scale, forKey: kCIInputScaleKey)
    guard let out = f.outputImage,
          let cg = CIContext().createCGImage(out, from: out.extent) else { return image }
    return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
}

let emblem = lanczos(emblemRaw, to: 660)

// Apple 的图标网格：1024 画布里，圆角方形占 824x824，圆角半径 185.4，
// 四周留白 100 —— 留白是 Dock 放大和投影用的，不能填满。
let canvas: CGFloat = 1024
let plate: CGFloat = 824
let radius: CGFloat = 185.4

struct IconView: View {
    let emblem: NSImage

    // 暴风城蓝 → 近黑的夜蓝，配徽章上的金色
    private let plateTop = Color(red: 0.11, green: 0.27, blue: 0.44)
    private let plateBottom = Color(red: 0.02, green: 0.07, blue: 0.13)
    private let goldLight = Color(red: 0.96, green: 0.79, blue: 0.42)
    private let goldDark = Color(red: 0.45, green: 0.29, blue: 0.08)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [plateTop, plateBottom],
                                     startPoint: .top, endPoint: .bottom))
                // 顶部一道很淡的高光，底板才不像一块死板的色块
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(RadialGradient(
                            colors: [Color.white.opacity(0.16), Color.clear],
                            center: UnitPoint(x: 0.5, y: -0.15),
                            startRadius: 0, endRadius: plate * 0.85))
                )
                // 金边：亮在上、暗在下，跟徽章的金框呼应
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [goldLight, goldDark],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: canvas * 0.006)
                )
                .frame(width: plate, height: plate)
                .shadow(color: .black.opacity(0.35),
                        radius: canvas * 0.02, x: 0, y: canvas * 0.012)

            Image(nsImage: emblem)
                .resizable()
                .interpolation(.high)
                .frame(width: canvas * 0.645, height: canvas * 0.645)
                .shadow(color: .black.opacity(0.45), radius: canvas * 0.016, y: canvas * 0.008)
        }
        .frame(width: canvas, height: canvas)
    }
}

@MainActor
func render(_ px: CGFloat) -> Data? {
    let r = ImageRenderer(content: IconView(emblem: emblem))
    r.scale = px / canvas          // 每个尺寸单独渲染，矢量部分始终是锐的
    guard let cg = r.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("wow-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// Apple 要求的整套尺寸阶梯
let steps: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

MainActor.assumeIsolated {
    for (name, px) in steps {
        guard let data = render(px) else {
            fputs("渲染 \(name) 失败\n", stderr); exit(1)
        }
        try! data.write(to: tmp.appendingPathComponent("\(name).png"))
    }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", outIcns.path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
guard p.terminationStatus == 0 else { fputs("iconutil 失败\n", stderr); exit(1) }
print("图标生成好了：\(outIcns.path)")
