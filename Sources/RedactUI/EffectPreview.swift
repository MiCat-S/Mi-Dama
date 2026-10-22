// 打码效果缩略图：都用真实渲染器生成，所见即所得
#if canImport(UIKit)
import CoreImage
import RedactKit
import SwiftUI

/// 效果缩略图：示例文字"手机 138 0013 8000"，只对号码打码，标签保留 —— 一眼看出效果盖在哪
enum EffectPreview {
    private static let size = CGSize(width: 240, height: 60)
    private static let font = UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
    private static let label = "手机" as NSString, number = "138 0013 8000" as NSString
    /// 小样在主线程同步渲染，单独用一个上下文：不和后台的全尺寸预览排同一条 GPU 队列，免得主线程等它
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// 号码所在的矩形（左上原点）
    private static let numberRect: CGRect = {
        let lw = label.size(withAttributes: [.font: font]).width
        let ns = number.size(withAttributes: [.font: font])
        return CGRect(x: 14 + lw + 8, y: (size.height - ns.height) / 2, width: ns.width, height: ns.height)
    }()

    private static let sample: CIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.94, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            label.draw(at: CGPoint(x: 14, y: numberRect.minY), withAttributes: attrs)
            number.draw(at: numberRect.origin, withAttributes: attrs)
        }
        return CIImage(cgImage: img.cgImage!)
    }()

    /// 方形小样：一块彩色格纹被该效果盖住后的样子（菜单图标、底部按钮用）
    @MainActor static func swatch(_ style: MaskStyle?, colorHex: String, side: CGFloat = 40) -> UIImage {
        let key = "\(style?.rawValue ?? "auto")-\(colorHex)-\(side)"
        if let cached = swatchCache[key] { return cached }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let size = CGSize(width: side, height: side)
        let sample = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors: [UIColor] = [.systemBlue, .systemPink, .systemYellow, .systemGreen, .systemPurple, .systemOrange]
            let cell = side / 4
            for r in 0..<4 {
                for c in 0..<4 {
                    colors[(r * 3 + c) % colors.count].setFill()
                    ctx.fill(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell))
                }
            }
        }
        var redactor = Redactor(context: context)
        redactor.fillColor = .fromHex(colorHex)
        // "自动"对图片区域默认用像素化，这里按头像类别演示
        let finding = Finding(kind: .chatAvatar, rect: CGRect(origin: .zero, size: CGSize(width: side * 3, height: side * 3)),
                              confidence: 1)
        let out = redactor.render(CIImage(cgImage: sample.cgImage!), findings: [finding], style: style)
        let image = redactor.makeCGImage(out).map { UIImage(cgImage: $0, scale: 3, orientation: .up) } ?? sample
        swatchCache[key] = image
        return image
    }

    @MainActor private static var swatchCache: [String: UIImage] = [:]

    static func image(_ style: MaskStyle?, colorHex: String) -> UIImage {
        var redactor = Redactor(context: context)
        redactor.fillColor = .fromHex(colorHex)
        let finding = Finding(kind: .phone, rect: numberRect, confidence: 1)
        let out = redactor.render(sample, findings: [finding], style: style)
        guard let cg = redactor.makeCGImage(out) else { return UIImage() }
        return UIImage(cgImage: cg)
    }
}
#endif
