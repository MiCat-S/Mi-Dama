// 生成 App 图标（1024×1024）：swift Tools/icon/render-icon.swift <输出目录> [concept]
// 输出 AppIcon.png（不透明）、AppIcon-Dark.png、AppIcon-Tinted.png（iOS 18+ 深色 / 着色外观）
import CoreGraphics
import Foundation
import ImageIO

let S: CGFloat = 1024

enum Variant { case light, dark, tinted }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func makeContext(opaque: Bool) -> CGContext {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    // 左上原点
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func save(_ ctx: CGContext, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

/// 马赛克格子的深浅（行优先），故意不规则，看起来像被打码的内容
let mosaicLevels: [[CGFloat]] = [
    [1.00, 0.55, 0.82, 0.40],
    [0.62, 0.95, 0.45, 0.78],
    [0.88, 0.42, 0.70, 1.00],
]

// MARK: - 概念 A：聊天气泡，第二行文字被打成马赛克

func conceptBubble(_ v: Variant) -> CGContext {
    let ctx = makeContext(opaque: v == .light)
    let fg: (CGFloat) -> CGColor
    switch v {
    case .light:
        linearGradient(ctx, [rgb(0x2F80FF), rgb(0x5B4BF5)], from: .zero, to: CGPoint(x: S, y: S))
        fg = { rgb(0xFFFFFF, $0) }
    case .dark:
        fg = { rgb(0x5C8DFF, $0) }
    case .tinted:
        fg = { rgb(0xFFFFFF, $0) }
    }
    // 气泡 + 左下尾巴：内容四周留白一致（约 96），气泡连尾巴整体居中
    // 主体和尾巴分开填充：合成一条路径时两段绕向相反，重叠处会被非零绕数规则挖空
    let body = CGRect(x: 168, y: 200, width: 688, height: 528)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 206, y: 576))
    tail.addCurve(to: CGPoint(x: 150, y: 834), control1: CGPoint(x: 222, y: 716), control2: CGPoint(x: 196, y: 788))
    tail.addCurve(to: CGPoint(x: 400, y: 716), control1: CGPoint(x: 250, y: 828), control2: CGPoint(x: 336, y: 786))
    tail.addLine(to: CGPoint(x: 400, y: 576))
    tail.closeSubpath()
    // 半透明时先合成到透明层，避免主体和尾巴重叠处颜色叠深
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(v == .light ? rgb(0xFFFFFF) : fg(1))
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 132, cornerHeight: 132, transform: nil))
    ctx.fillPath()
    ctx.addPath(tail)
    ctx.fillPath()
    ctx.endTransparencyLayer()
    if v != .light {
        // 深色 / 着色版：气泡只是一层淡底，用"清除后重画"的方式把它压到目标不透明度
        let alpha: CGFloat = v == .dark ? 0.3 : 0.32
        ctx.saveGState()
        ctx.setBlendMode(.destinationIn)
        ctx.setFillColor(rgb(0x000000, alpha))
        ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        ctx.restoreGState()
    }
    // 第一行：普通文字
    let lineColor = v == .light ? rgb(0xC9D4EC) : fg(0.9)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 264, y: 296, width: 352, height: 64), cornerWidth: 32, cornerHeight: 32, transform: nil))
    ctx.setFillColor(lineColor)
    ctx.fillPath()
    // 第二行：马赛克（格子够大，缩到设置页图标尺寸也看得出是马赛克）
    let cell: CGFloat = 124, origin = CGPoint(x: 264, y: 392)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: origin.x, y: origin.y, width: cell * 4, height: cell * 2),
                       cornerWidth: 28, cornerHeight: 28, transform: nil))
    ctx.clip()
    let palette: [UInt32] = [0x2F80FF, 0x6A5CFF, 0x22B8F0, 0x8B7BFF, 0x3F6BFF, 0x19A3E0, 0x7F6CF6, 0x4D8DFF]
    for r in 0..<2 {
        for c in 0..<4 {
            let rect = CGRect(x: origin.x + CGFloat(c) * cell, y: origin.y + CGFloat(r) * cell, width: cell, height: cell)
            let level = mosaicLevels[r][c]
            ctx.setFillColor(v == .light ? rgb(palette[(r * 4 + c) % palette.count]) : fg(0.35 + 0.65 * level))
            ctx.fill(rect)
        }
    }
    ctx.restoreGState()
    return ctx
}

// MARK: - 概念 B：截图取景框 + 中间马赛克

func conceptFrame(_ v: Variant) -> CGContext {
    let ctx = makeContext(opaque: v == .light)
    let fg: (CGFloat) -> CGColor
    switch v {
    case .light:
        linearGradient(ctx, [rgb(0x2F80FF), rgb(0x5B4BF5)], from: .zero, to: CGPoint(x: S, y: S))
        fg = { rgb(0xFFFFFF, $0) }
    case .dark:
        fg = { rgb(0x6E98FF, $0) }
    case .tinted:
        fg = { rgb(0xFFFFFF, $0) }
    }
    // 四角取景框
    let inset: CGFloat = 216, arm: CGFloat = 158, w: CGFloat = 62
    ctx.setStrokeColor(fg(1))
    ctx.setLineWidth(w)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let a = inset, b = S - inset
    for (corner, dx, dy) in [(CGPoint(x: a, y: a), 1.0, 1.0), (CGPoint(x: b, y: a), -1.0, 1.0),
                             (CGPoint(x: a, y: b), 1.0, -1.0), (CGPoint(x: b, y: b), -1.0, -1.0)] {
        ctx.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        ctx.addLine(to: corner)
        ctx.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
    }
    ctx.strokePath()
    // 中间 3×3 马赛克
    let cell: CGFloat = 104, gap: CGFloat = 10
    let total = cell * 3 + gap * 2, start = (S - total) / 2
    let levels: [[CGFloat]] = [[1.0, 0.45, 0.8], [0.55, 0.95, 0.38], [0.85, 0.5, 1.0]]
    for r in 0..<3 {
        for c in 0..<3 {
            let rect = CGRect(x: start + CGFloat(c) * (cell + gap), y: start + CGFloat(r) * (cell + gap), width: cell, height: cell)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil))
            ctx.setFillColor(fg(levels[r][c]))
            ctx.fillPath()
        }
    }
    return ctx
}

// MARK: - 概念 C：盾牌里嵌马赛克

func conceptShield(_ v: Variant) -> CGContext {
    let ctx = makeContext(opaque: v == .light)
    let fg: (CGFloat) -> CGColor
    switch v {
    case .light:
        linearGradient(ctx, [rgb(0x1FB5A8), rgb(0x2F6BFF)], from: .zero, to: CGPoint(x: S, y: S))
        fg = { rgb(0xFFFFFF, $0) }
    case .dark:
        fg = { rgb(0x4FC3B6, $0) }
    case .tinted:
        fg = { rgb(0xFFFFFF, $0) }
    }
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 170))
    shield.addCurve(to: CGPoint(x: 802, y: 272), control1: CGPoint(x: 600, y: 236), control2: CGPoint(x: 700, y: 268))
    shield.addCurve(to: CGPoint(x: 512, y: 860), control1: CGPoint(x: 816, y: 560), control2: CGPoint(x: 700, y: 760))
    shield.addCurve(to: CGPoint(x: 222, y: 272), control1: CGPoint(x: 324, y: 760), control2: CGPoint(x: 208, y: 560))
    shield.addCurve(to: CGPoint(x: 512, y: 170), control1: CGPoint(x: 324, y: 268), control2: CGPoint(x: 424, y: 236))
    shield.closeSubpath()
    ctx.addPath(shield)
    ctx.setFillColor(fg(v == .light ? 1 : 0.25))
    ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(shield)
    ctx.clip()
    let cell: CGFloat = 96, start = CGPoint(x: 512 - cell * 2, y: 330)
    let palette: [UInt32] = [0x1FB5A8, 0x2F6BFF, 0x4C9BFF, 0x17A393, 0x5B7CFF, 0x2BC7B8]
    for r in 0..<3 {
        for c in 0..<4 {
            let rect = CGRect(x: start.x + CGFloat(c) * cell, y: start.y + CGFloat(r) * cell, width: cell, height: cell)
            ctx.setFillColor(v == .light ? rgb(palette[(r * 4 + c * 5) % palette.count], 0.35 + 0.65 * mosaicLevels[r][c])
                                         : fg(0.35 + 0.65 * mosaicLevels[r][c]))
            ctx.fill(rect)
        }
    }
    ctx.restoreGState()
    return ctx
}

// MARK: -

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let concepts: [String: (Variant) -> CGContext] = ["bubble": conceptBubble, "frame": conceptFrame, "shield": conceptShield]
let selected = args.count > 2 ? [args[2]] : concepts.keys.sorted()
for name in selected {
    guard let draw = concepts[name] else { continue }
    let prefix = selected.count > 1 ? "\(name)-" : ""
    save(draw(.light), out.appendingPathComponent("\(prefix)AppIcon.png"))
    save(draw(.dark), out.appendingPathComponent("\(prefix)AppIcon-Dark.png"))
    save(draw(.tinted), out.appendingPathComponent("\(prefix)AppIcon-Tinted.png"))
}
print("done: \(selected.joined(separator: ", "))")
