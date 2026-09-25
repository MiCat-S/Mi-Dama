// Core Image 打码：
//  1. 每一处都从"当前结果"取像素 —— 后加的效果不会把之前盖住的内容翻出来
//  2. clampedToExtent() 把边缘像素向外延展 —— 贴边模糊不会透出原图
//  3. 强度随区域大小变化 —— 大图上的人脸、小字都能盖住
//  4. 色块 / 杂讯色块 / 彩虹条 / 彩虹格 只由区域位置和颜色生成，完全不读原图
import CoreImage
import CoreImage.CIFilterBuiltins
import simd

public struct Redactor {
    /// 色块、杂讯色块使用的颜色
    public var fillColor = CIColor(red: 0.08, green: 0.08, blue: 0.09)
    let context: CIContext

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    /// - Parameters:
    ///   - source: 已按方向校正的原图
    ///   - style: 全局样式。优先级：单处指定的样式 > 全局样式 > 类别默认样式；nil 表示"自动"
    public func render(_ source: CIImage, findings: [Finding], style: MaskStyle? = nil) -> CIImage {
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let extent = image.extent
        let enabled = findings.filter(\.isEnabled)
        guard !enabled.isEmpty else { return image }
        let chosen = { (f: Finding) in f.style ?? style ?? .default(for: f.kind) }
        // "抹除文字"需要采样背景色，只在用得到时才读一次像素
        let pixels = enabled.contains { chosen($0) == .hideText } ? RGBAImage(image, context: context) : nil

        var result = image
        for f in enabled {
            let rect = padded(f).intersection(CGRect(origin: .zero, size: extent.size))
            guard !rect.isEmpty else { continue }
            let ciRect = rect.flippedVertically(inHeight: extent.height).integral
            let patch = makePatch(chosen(f), kind: f.kind, rect: rect, ciRect: ciRect, base: result, pixels: pixels)
            result = patch.cropped(to: ciRect).composited(over: result)
        }
        return result.cropped(to: extent)
    }

    public func makeCGImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }

    // MARK: -

    /// 文字按行高外扩，盖住抗锯齿边缘和 OCR 框的误差
    private func padded(_ f: Finding) -> CGRect {
        let r = f.rect
        let pad = f.kind.isText ? max(2, r.height * 0.12) : (f.kind == .face ? r.height * 0.1 : 1)
        return r.insetBy(dx: -pad, dy: -pad)
    }

    private func makePatch(_ style: MaskStyle, kind: FindingKind, rect: CGRect, ciRect: CGRect,
                           base: CIImage, pixels: RGBAImage?) -> CIImage {
        let short = min(rect.width, rect.height)
        switch style {
        case .solid:
            return CIImage(color: fillColor)
        case .hideText:
            // 背景足够纯：用背景色抹掉，看起来像原本没写字
            if let stats = pixels?.ringStats(around: rect), stats.agreement >= 0.7 {
                let c = stats.median / 255
                return CIImage(color: CIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z)))
            }
            // 背景复杂：退回大块像素化（每个字只剩 1–2 块，无法还原）
            return pixellate(base, blockSize: max(8, rect.height / 2), origin: ciRect.origin)
        case .pixelate:
            let block = kind.isText ? max(8, rect.height / 2) : max(8, short / 5)
            return pixellate(base, blockSize: block, origin: ciRect.origin)
        case .blur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = base.clampedToExtent()
            f.radius = Float(kind.isText ? max(12, rect.height) : max(16, short / 4))
            return f.outputImage ?? CIImage(color: fillColor)
        case .noiseBlock:
            // 颗粒约为区域短边的 1/12，亮度在 ±18% 内随机抖动
            var rng = SeededRandom(ciRect)
            let (cols, rows) = grid(ciRect, cell: max(2, short / 12))
            let base = SIMD3<Float>(Float(fillColor.red), Float(fillColor.green), Float(fillColor.blue))
            let cells = (0..<(cols * rows)).map { _ in
                simd_clamp(base * rng.float(in: 0.82...1.18), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            }
            return bitmapPatch(cells, cols: cols, rows: rows, in: ciRect)
        case .rainbowBars:
            return bitmapPatch(Self.rainbow, cols: 1, rows: Self.rainbow.count, in: ciRect)
        case .rainbowGrid:
            var rng = SeededRandom(ciRect)
            let (cols, rows) = grid(ciRect, cell: max(6, short / (kind.isText ? 1.5 : 4)))
            var cells: [SIMD3<Float>] = []
            for _ in 0..<(cols * rows) {
                // 相邻两格不同色，格子才分得清
                var c = Self.rainbow[rng.int(Self.rainbow.count)]
                while c == cells.last { c = Self.rainbow[rng.int(Self.rainbow.count)] }
                cells.append(c)
            }
            return bitmapPatch(cells, cols: cols, rows: rows, in: ciRect)
        }
    }

    private func pixellate(_ base: CIImage, blockSize: CGFloat, origin: CGPoint) -> CIImage {
        let f = CIFilter.pixellate()
        f.inputImage = base.clampedToExtent()
        f.scale = Float(blockSize)
        f.center = origin
        return f.outputImage ?? CIImage(color: fillColor)
    }

    private func grid(_ rect: CGRect, cell: CGFloat) -> (cols: Int, rows: Int) {
        (max(1, Int((rect.width / cell).rounded())), max(1, Int((rect.height / cell).rounded())))
    }

    /// cols × rows 个颜色用最近邻放大铺满区域：一个 Core Image 节点搞定整片图案
    private func bitmapPatch(_ colors: [SIMD3<Float>], cols: Int, rows: Int, in rect: CGRect) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: cols * rows * 4)
        for (i, c) in colors.prefix(cols * rows).enumerated() {
            bytes[i * 4] = UInt8((c.x * 255).rounded())
            bytes[i * 4 + 1] = UInt8((c.y * 255).rounded())
            bytes[i * 4 + 2] = UInt8((c.z * 255).rounded())
        }
        let img = CIImage(bitmapData: Data(bytes), bytesPerRow: cols * 4, size: CGSize(width: cols, height: rows),
                          format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return img.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: rect.width / CGFloat(cols), y: rect.height / CGFloat(rows)))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    static let rainbow: [SIMD3<Float>] = [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x32ADE6, 0x007AFF, 0xAF52DE].map {
        SIMD3(Float(($0 >> 16) & 0xFF), Float(($0 >> 8) & 0xFF), Float($0 & 0xFF)) / 255
    }
}

/// 以区域位置为种子的随机数：同一区域每次渲染图案一致（预览与导出一致），且与原图内容无关
struct SeededRandom {
    private var state: UInt64

    init(_ rect: CGRect) {
        let x = UInt64(max(0, rect.minX)), y = UInt64(max(0, rect.minY))
        state = (x &* 0x9E3779B97F4A7C15) ^ (y &* 0xBF58476D1CE4E5B9) ^ 0x94D049BB133111EB
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + Float(next() % 10_000) / 10_000 * (range.upperBound - range.lowerBound)
    }
}
