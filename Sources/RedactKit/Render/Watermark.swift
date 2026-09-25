// 全图平铺文字水印（证件照常用："仅供办理 XX 使用"）
import CoreGraphics
import CoreImage
import CoreText
import Foundation

public struct WatermarkSpec: Codable, Hashable, Sendable {
    public var text: String
    /// 字号 = 图片宽度 × fontScale
    public var fontScale: CGFloat
    public var colorHex: String
    /// 0–1
    public var opacity: CGFloat
    /// 负值向右上倾斜
    public var angleDegrees: CGFloat
    /// 行、列之间的空隙 = 字号 × spacing
    public var spacing: CGFloat

    public init(text: String = "", fontScale: CGFloat = 0.045, colorHex: String = "#000000",
                opacity: CGFloat = 0.25, angleDegrees: CGFloat = -30, spacing: CGFloat = 2.0) {
        self.text = text
        self.fontScale = fontScale
        self.colorHex = colorHex
        self.opacity = opacity
        self.angleDegrees = angleDegrees
        self.spacing = spacing
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum Watermark {
    /// 在与原图等大的透明画布上画好水印，再叠到原图上方
    public static func overlay(_ image: CIImage, spec: WatermarkSpec) -> CIImage {
        let img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let W = Int(img.extent.width.rounded()), H = Int(img.extent.height.rounded())
        guard !spec.isEmpty, W > 0, H > 0, spec.opacity > 0,
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }

        // 左上原点，y 向下
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let fontSize = max(10, CGFloat(W) * spec.fontScale)
        let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, fontSize, nil)
        let c = CIColor.fromHex(spec.colorHex)
        let color = CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: min(1, max(0, spec.opacity)))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: spec.text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let gap = fontSize * max(0.2, spec.spacing)
        let stepX = lineWidth + gap, stepY = ascent + descent + gap

        // 绕中心旋转后，按对角线长度铺满，保证旋转后四角也有水印；隔行错开半格
        let diag = (CGFloat(W * W + H * H)).squareRoot()
        ctx.translateBy(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
        ctx.rotate(by: spec.angleDegrees * .pi / 180)
        var row = 0
        var y = -diag / 2
        while y < diag / 2 {
            var x = -diag / 2 - (row % 2 == 1 ? stepX / 2 : 0)
            while x < diag / 2 {
                ctx.textPosition = CGPoint(x: x, y: y + ascent)
                CTLineDraw(line, ctx)
                x += stepX
            }
            y += stepY
            row += 1
        }
        guard let layer = ctx.makeImage() else { return img }
        // 在 sRGB（带伽马）空间里混合，和设计软件 / CoreGraphics 一致；
        // Core Image 默认在线性空间混合，80% 不透明度看起来会淡很多
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let top = CIImage(cgImage: layer).matchedFromWorkingSpace(to: srgb),
              let base = img.matchedFromWorkingSpace(to: srgb),
              let mixed = top.composited(over: base).matchedToWorkingSpace(from: srgb) else {
            return CIImage(cgImage: layer).composited(over: img).cropped(to: img.extent)
        }
        return mixed.cropped(to: img.extent)
    }
}
