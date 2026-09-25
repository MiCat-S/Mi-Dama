// 生成合成聊天截图：chat-synth <输出目录> [数量]
import ChatSynth
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "testdata/synthetic")
let count = args.count > 2 ? Int(args[2]) ?? 24 : 24
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// 常见机型宽度：@3x 的 iPhone、@2x 的旧 iPhone、1080 宽的安卓
if let one = ProcessInfo.processInfo.environment["SYNTH_ONE"] {
    // SYNTH_ONE="宽,倍率,dark(0/1),group(0/1),circle(0/1),seed" 复现单个用例
    let p = one.split(separator: ",").map(String.init)
    let cfg = SynthConfig(widthPx: Int(p[0])!, scale: CGFloat(Double(p[1])!), dark: p[2] == "1", group: p[3] == "1",
                          circleAvatars: p[4] == "1", seed: UInt64(p[5])!)
    let r = ChatSynth.render(cfg)
    let url = outDir.appendingPathComponent("case.png")
    let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, r.image, nil); CGImageDestinationFinalize(d)
    try JSONEncoder().encode(r.labels).write(to: outDir.appendingPathComponent("case.labels.json"))
    exit(0)
}
let devices: [(Int, CGFloat)] = [(1170, 3), (1179, 3), (1290, 3), (750, 2), (828, 2), (1080, 2.75)]
for i in 0..<count {
    let (w, s) = devices[i % devices.count]
    let cfg = SynthConfig(widthPx: w, scale: s, dark: i % 3 == 2, group: i % 4 != 3, circleAvatars: i % 5 == 4, seed: UInt64(i + 1))
    let result = ChatSynth.render(cfg)
    let name = String(format: "synth-%02d-%@%@", i, cfg.group ? "group" : "1on1", cfg.dark ? "-dark" : "")
    let png = outDir.appendingPathComponent(name + ".png")
    let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, result.image, nil)
    CGImageDestinationFinalize(dest)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(result.labels).write(to: outDir.appendingPathComponent(name + ".labels.json"))
}
print("生成 \(count) 张到 \(outDir.path)")
