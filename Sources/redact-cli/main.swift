// macOS 命令行：
//   redact-cli detect <图片...> [--out 目录]   识别 → 输出标注图、打码图、JSON
//   redact-cli eval <目录> [--out 目录]         对带 .labels.json 的合成图统计召回率 / 精确率
import ChatSynth
import CoreImage
import CoreText
import Foundation
import ImageIO
import RedactKit

let ciContext = CIContext(options: [.cacheIntermediates: false])
let pipeline = DetectionPipeline(context: ciContext)
let redactor = Redactor(context: ciContext)

func loadImage(_ url: URL) -> CIImage? {
    CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try Exporter.data(image, format: .png).write(to: url)
}

// MARK: - 标注图

let kindColors: [FindingKind: (CGFloat, CGFloat, CGFloat)] = [
    .chatAvatar: (0.1, 0.6, 1), .chatNickname: (1, 0.2, 0.6), .chatTitle: (0.6, 0.3, 1), .chatSystemMessage: (0.6, 0.6, 0.6),
    .face: (1, 0.5, 0), .qrCode: (0.9, 0.9, 0), .barcode: (0.9, 0.9, 0),
]

/// 在原图上画出识别框：实线 = 默认勾选，虚线 = 默认不勾选；missed 用红色粗框标出漏检的标注
func overlay(_ image: CIImage, findings: [Finding], missed: [CGRect] = []) -> CGImage? {
    guard let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    let lw = max(2, CGFloat(w) / 400)
    let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, max(10, CGFloat(w) / 55), nil)
    for f in findings {
        let (r, g, b) = kindColors[f.kind] ?? (0, 0.8, 0.3)
        let color = CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        ctx.setStrokeColor(color); ctx.setLineWidth(lw)
        ctx.setLineDash(phase: 0, lengths: f.isEnabled ? [] : [lw * 3, lw * 2])
        ctx.stroke(f.rect)
        let text = "\(f.kind.label) \(Int(f.confidence * 100))"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color]))
        ctx.textPosition = CGPoint(x: f.rect.minX, y: max(CTFontGetAscent(font), f.rect.minY - 3))
        CTLineDraw(line, ctx)
    }
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.setLineWidth(lw * 2.5)
    for m in missed { ctx.stroke(m.insetBy(dx: -lw * 2, dy: -lw * 2)) }
    return ctx.makeImage()
}

// MARK: - 命令

func outputDir(_ args: [String], default def: String) throws -> URL {
    let dir = URL(fileURLWithPath: args.firstIndex(of: "--out").map { args[$0 + 1] } ?? def)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func runDetect(_ args: [String]) throws {
    let out = try outputDir(args, default: "testdata/out")
    let files = args.filter { !$0.hasPrefix("--") && $0 != (args.firstIndex(of: "--out").map { args[$0 + 1] } ?? "") }
    for path in files {
        let url = URL(fileURLWithPath: path)
        guard let image = loadImage(url) else { print("✗ 无法读取 \(path)"); continue }
        let start = Date()
        let findings = try pipeline.detect(image)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let base = url.deletingPathExtension().lastPathComponent
        if let o = overlay(image, findings: findings) { try writePNG(o, to: out.appendingPathComponent(base + ".overlay.png")) }
        if let r = redactor.makeCGImage(redactor.render(image, findings: findings)) {
            try writePNG(r, to: out.appendingPathComponent(base + ".redacted.png"))
        }
        let summary = Dictionary(grouping: findings, by: \.kind).map { "\($0.key.label)×\($0.value.count)" }.sorted().joined(separator: " ")
        print("\(base)  \(Int(image.extent.width))×\(Int(image.extent.height))  \(ms)ms  \(summary)")
    }
}

func runEval(_ args: [String]) throws {
    let dir = URL(fileURLWithPath: args.first { !$0.hasPrefix("--") } ?? "testdata/synthetic")
    let out = try outputDir(args, default: "testdata/out/eval")
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
    let kindMap: [String: FindingKind] = ["avatar": .chatAvatar, "nickname": .chatNickname, "title": .chatTitle, "system": .chatSystemMessage]
    var tp: [String: Int] = [:], fn: [String: Int] = [:], fp: [String: Int] = [:]

    for png in files {
        let labelURL = png.deletingPathExtension().appendingPathExtension("labels.json")
        guard let data = try? Data(contentsOf: labelURL), let labels = try? JSONDecoder().decode([SynthLabel].self, from: data),
              let image = loadImage(png) else { continue }
        let findings = try pipeline.detect(image)
        var missed: [CGRect] = []
        var falsePositives = 0
        for (name, kind) in kindMap {
            let truth = labels.filter { $0.kind == name }.map(\.rect)
            let found = findings.filter { $0.kind == kind && $0.isEnabled }.map(\.rect)
            // 命中标准：交并比 ≥ 0.4，或检测框覆盖了标注框 90% 以上（打码只要盖住就算）
            let hit = { (t: CGRect, f: CGRect) in t.iou(f) >= 0.4 || t.intersection(f).area >= t.area * 0.9 }
            for t in truth {
                if found.contains(where: { hit(t, $0) }) { tp[name, default: 0] += 1 } else { fn[name, default: 0] += 1; missed.append(t) }
            }
            let extra = found.filter { f in !truth.contains { hit($0, f) } }.count
            fp[name, default: 0] += extra
            falsePositives += extra
        }
        let base = png.deletingPathExtension().lastPathComponent
        if !missed.isEmpty || falsePositives > 0, let o = overlay(image, findings: findings, missed: missed) {
            try writePNG(o, to: out.appendingPathComponent(base + ".miss.png"))
        }
        print("\(base): 漏检 \(missed.count)  误报 \(falsePositives)")
    }
    print("\n类别        召回率            精确率")
    for name in ["avatar", "nickname", "title", "system"] {
        let t = tp[name, default: 0], n = fn[name, default: 0], p = fp[name, default: 0]
        let recall = t + n > 0 ? Double(t) / Double(t + n) : 1
        let precision = t + p > 0 ? Double(t) / Double(t + p) : 1
        print(String(format: "%-10@  %5.1f%% (%d/%d)   %5.1f%% (误报 %d)", name as NSString, recall * 100, t, t + n, precision * 100, p))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "detect": try runDetect(Array(args.dropFirst()))
case "eval": try runEval(Array(args.dropFirst()))
default: print("用法：redact-cli detect <图片...> [--out 目录] | redact-cli eval <目录> [--out 目录]")
}
