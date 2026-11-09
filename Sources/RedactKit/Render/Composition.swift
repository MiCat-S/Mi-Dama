// 拼图：几张图上下 / 左右拼成一张。
//  · 只缩小不放大：上下拼统一成最窄那张的宽度，左右拼统一成最矮那张的高度
//  · 打码在拼好的图上做（先拼、再打码、再按导出设置缩放），所以拼接时的缩放不会削弱打码
//  · 识别仍然逐张做（聊天布局分析依赖"头像贴着左右边缘""标题在最上面"），结果按位置换算到拼图上
import CoreGraphics
import CoreImage

public struct MergeLayout: Hashable, Codable, Sendable {
    public enum Axis: String, Codable, CaseIterable, Sendable {
        case vertical, horizontal
        public var label: String { self == .vertical ? "上下" : "左右" }
    }

    /// 两张图之间的间距，按拼好后最短的那条图边换算
    public enum Gap: String, Codable, CaseIterable, Sendable {
        case none, thin, thick
        public var label: String {
            switch self {
            case .none: "无"
            case .thin: "细"
            case .thick: "粗"
            }
        }
        var fraction: CGFloat {
            switch self {
            case .none: 0
            case .thin: 0.02
            case .thick: 0.05
            }
        }
    }

    /// 间距的颜色
    public enum Background: String, Codable, CaseIterable, Sendable {
        case white, black
        public var label: String { self == .white ? "白" : "黑" }
        public var color: CIColor { self == .white ? CIColor(red: 1, green: 1, blue: 1) : CIColor(red: 0, green: 0, blue: 0) }
    }

    public var axis: Axis
    public var gap: Gap
    public var background: Background
    /// 拼接顺序（输入图片的下标）；不是 0..<n 的排列时按输入顺序
    public var order: [Int]

    public init(axis: Axis, gap: Gap = .thin, background: Background = .white, order: [Int]) {
        self.axis = axis
        self.gap = gap
        self.background = background
        self.order = order
    }

    /// 默认布局：全是竖图（一般是截图）左右拼，结果接近方形，聊天里的缩略图不会太小；其余上下拼
    public static func defaultAxis(for sizes: [CGSize]) -> Axis {
        sizes.allSatisfy { $0.height > $0.width } ? .horizontal : .vertical
    }
}

/// 一次拼接的几何：画布尺寸和每张图在画布上的位置（左上原点，与 Finding 一致）
public struct Composition: Hashable, Sendable {
    /// 拼好的图最多这么多像素（和单张长截图同一量级），超过整体等比缩小
    public static let maxPixels: CGFloat = 24_000_000

    public let layout: MergeLayout
    /// 各张原图的尺寸（按输入顺序）
    public let partSizes: [CGSize]
    /// 各张图在画布上的位置（按输入顺序，不是拼接顺序），整数像素
    public let frames: [CGRect]
    public let canvasSize: CGSize

    public init(partSizes: [CGSize], layout: MergeLayout, maxPixels: CGFloat = Composition.maxPixels) {
        let n = partSizes.count
        precondition(n > 0 && partSizes.allSatisfy { $0.width > 0 && $0.height > 0 }, "拼图需要至少一张有效尺寸的图")
        var layout = layout
        if layout.order.sorted() != Array(0..<n) { layout.order = Array(0..<n) }
        self.layout = layout
        self.partSizes = partSizes

        let vertical = layout.axis == .vertical
        // 统一的那条边（上下拼 = 宽，左右拼 = 高）取最小值：只缩不放
        let commonUncapped = partSizes.map { vertical ? $0.width : $0.height }.min()!
        let tiles = { (common: CGFloat) -> [CGFloat] in
            partSizes.map { s in vertical ? s.height * common / s.width : s.width * common / s.height }
        }
        let gapOf = { (common: CGFloat, tiles: [CGFloat]) -> CGFloat in
            n > 1 ? (min(common, tiles.min()!) * layout.gap.fraction).rounded() : 0
        }
        let rawTiles = tiles(commonUncapped)
        let rawLength = rawTiles.reduce(0, +) + gapOf(commonUncapped, rawTiles) * CGFloat(n - 1)
        let scale = min(1, (maxPixels / (commonUncapped * rawLength)).squareRoot())

        let common = max(1, (commonUncapped * scale).rounded(.down))
        let lengths = tiles(common).map { max(1, $0.rounded()) }
        let gap = gapOf(common, lengths)
        var frames = [CGRect](repeating: .zero, count: n)
        var cursor: CGFloat = 0
        for i in layout.order {
            frames[i] = vertical
                ? CGRect(x: 0, y: cursor, width: common, height: lengths[i])
                : CGRect(x: cursor, y: 0, width: lengths[i], height: common)
            cursor += lengths[i] + gap
        }
        let length = cursor - gap
        self.frames = frames
        canvasSize = vertical ? CGSize(width: common, height: length) : CGSize(width: length, height: common)
    }

    private func scale(_ part: Int) -> (x: CGFloat, y: CGFloat) {
        (frames[part].width / partSizes[part].width, frames[part].height / partSizes[part].height)
    }

    /// 第 part 张图上的区域 → 画布坐标
    public func toCanvas(_ rect: CGRect, from part: Int) -> CGRect {
        let (sx, sy) = scale(part)
        let f = frames[part]
        return CGRect(x: f.minX + rect.minX * sx, y: f.minY + rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
    }

    /// 画布上的区域 → 落在各张图上的部分（各张图自己的坐标）；落在间距里的部分不算
    public func toParts(_ rect: CGRect) -> [(part: Int, rect: CGRect)] {
        frames.indices.compactMap { i in
            let inter = rect.intersection(frames[i])
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { return nil }
            let (sx, sy) = scale(i)
            let f = frames[i]
            return (i, CGRect(x: (inter.minX - f.minX) / sx, y: (inter.minY - f.minY) / sy,
                              width: inter.width / sx, height: inter.height / sy))
        }
    }

    // MARK: - 区域换算

    /// 各张图上的区域 → 画布坐标。勾选、效果、id 都保留（单张里做过的修改跟着带过来）
    public func findings(from parts: [[Finding]]) -> [Finding] {
        zip(parts.indices, parts).flatMap { part, findings in
            findings.map { f in
                var f = f
                f.rect = toCanvas(f.rect, from: part)
                return f
            }
        }
    }

    public func textLines(from parts: [[TextLine]]) -> [TextLine] {
        zip(parts.indices, parts).flatMap { part, lines in
            lines.map { TextLine(rect: toCanvas($0.rect, from: part), text: $0.text) }
        }
    }

    /// 换布局：画布上的区域换算到新布局（两次拼接必须是同一组图）。
    /// 横跨接缝的区域（马克笔拉过两张图）拆成几段各自跟着图走，换布局也不会露出一半；完全落在间距里的丢掉
    public func remap(_ findings: [Finding], to new: Composition) -> [Finding] {
        precondition(new.partSizes == partSizes, "只能在同一组图的两种布局之间换算")
        return findings.flatMap { f in
            toParts(f.rect).enumerated().map { n, piece in
                let rect = new.toCanvas(piece.rect, from: piece.part)
                if n == 0 {
                    var moved = f
                    moved.rect = rect
                    return moved
                }
                return Finding(kind: f.kind, rect: rect, confidence: f.confidence, text: f.text,
                               isEnabled: f.isEnabled, style: f.style)
            }
        }
    }

    // MARK: - 合成

    /// 把各张图（已按方向校正，按输入顺序）拼成一张，间距填背景色
    public func compose(_ images: [CIImage]) -> CIImage {
        precondition(images.count == frames.count)
        let canvas = CGRect(origin: .zero, size: canvasSize)
        var result = CIImage(color: layout.background.color).cropped(to: canvas)
        for (i, image) in images.enumerated() {
            let img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let f = frames[i]
            // Core Image 是左下原点
            let target = CGRect(x: f.minX, y: canvasSize.height - f.maxY, width: f.width, height: f.height)
            let sx = f.width / img.extent.width, sy = f.height / img.extent.height
            // 先延展边缘再缩放，避免最外一圈混进透明像素、和间距颜色混在一起
            var tile = img.clampedToExtent()
            if abs(sx - 1) > 1e-6 || abs(sy - 1) > 1e-6 {
                tile = tile.applyingFilter("CILanczosScaleTransform",
                                           parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
            }
            result = tile.transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
                .cropped(to: target)
                .composited(over: result)
        }
        return result
    }
}
