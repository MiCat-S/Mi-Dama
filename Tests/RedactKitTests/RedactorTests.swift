import CoreImage
import ImageIO
import Testing
@testable import RedactKit

/// 用左上原点坐标绘制测试图
private func makeImage(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CIImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(ctx)
    return CIImage(cgImage: ctx.makeImage()!)
}

/// 竖条纹模拟文字笔画（高对比、高频）
private func stripes(_ ctx: CGContext, in rect: CGRect) {
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    var x = rect.minX
    while x < rect.maxX {
        ctx.fill(CGRect(x: x, y: rect.minY, width: 3, height: rect.height))
        x += 6
    }
}

/// 某一行在 [x0, x1) 内的亮度标准差：越大说明原始笔画越清晰
private func rowStd(_ img: RGBAImage, y: Int, x0: Int, x1: Int) -> Float {
    let vals = (x0..<x1).map { x -> Float in let c = img.rgb(x, y); return (c.x + c.y + c.z) / 3 }
    let mean = vals.reduce(0, +) / Float(vals.count)
    return (vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(vals.count)).squareRoot()
}

@Suite("打码渲染")
struct RedactorTests {
    let context = CIContext()

    @Test func 抹除文字只渲染局部也采到同样的背景() {
        // 左右两种底色 + 顶部条纹：不同位置的框外一圈颜色各不相同
        let src = makeImage(width: 300, height: 120) { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 150, height: 120))
            stripes(ctx, in: CGRect(x: 0, y: 0, width: 300, height: 12))
        }
        let full = RGBAImage(src, context: context)
        // 普通位置、小数坐标、贴着四边、跨出图外
        let rects = [CGRect(x: 40, y: 30, width: 100, height: 20), CGRect(x: 140.6, y: 50.2, width: 30.5, height: 9.3),
                     CGRect(x: 0, y: 0, width: 50, height: 14), CGRect(x: 280, y: 100, width: 20, height: 20),
                     CGRect(x: -5, y: 60, width: 30, height: 30), CGRect(x: 1, y: 1, width: 298, height: 118)]
        for rect in rects {
            let expected = full.ringStats(around: rect)
            let actual = RGBAImage.ringStats(of: src, around: rect, context: context)
            #expect(actual?.median == expected?.median, "\(rect)")
            #expect(actual?.agreement == expected?.agreement, "\(rect)")
        }
    }

    @Test func 像素缓冲第0行是图像顶部() {
        let img = makeImage(width: 10, height: 10) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 5))   // 上半红
        }
        let px = RGBAImage(img, context: context)
        #expect(px.rgb(5, 0).x > 200 && px.rgb(5, 0).y < 50)
        #expect(px.rgb(5, 9).y > 200)
    }

    @Test func 贴边模糊不透出原图() {
        let src = makeImage(width: 200, height: 100) { stripes($0, in: CGRect(x: 0, y: 70, width: 200, height: 30)) }
        let finding = Finding(kind: .face, rect: CGRect(x: 0, y: 60, width: 200, height: 40), confidence: 1, style: .blur)
        let out = RGBAImage(Redactor(context: context).render(src, findings: [finding]), context: context)
        let before = rowStd(RGBAImage(src, context: context), y: 99, x0: 20, x1: 180)
        let after = rowStd(out, y: 99, x0: 20, x1: 180)
        #expect(before > 100)
        #expect(after < 6, "最后一行仍可见笔画结构：std=\(after)")
    }

    @Test func 后加模糊不会翻出先前的纯色遮挡() {
        let src = makeImage(width: 200, height: 100) { stripes($0, in: CGRect(x: 20, y: 30, width: 160, height: 40)) }
        let solid = Finding(kind: .phone, rect: CGRect(x: 10, y: 25, width: 180, height: 50), confidence: 1, style: .solid)
        let blur = Finding(kind: .face, rect: CGRect(x: 0, y: 0, width: 200, height: 100), confidence: 1, style: .blur)
        let out = RGBAImage(Redactor(context: context).render(src, findings: [solid, blur]), context: context)
        #expect(rowStd(out, y: 50, x0: 60, x1: 140) < 2)
    }

    @Test func 纯色背景上抹除文字不留痕迹() {
        let bg = CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)
        let src = makeImage(width: 200, height: 60) { ctx in
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 60))
            stripes(ctx, in: CGRect(x: 40, y: 20, width: 100, height: 20))
        }
        let f = Finding(kind: .phone, rect: CGRect(x: 40, y: 20, width: 100, height: 20), confidence: 1)
        #expect(f.resolvedStyle == .hideText)
        let background = RGBAImage(src, context: context).rgb(5, 5)
        let out = RGBAImage(Redactor(context: context).render(src, findings: [f]), context: context)
        for y in [22, 30, 38] {
            #expect(rowStd(out, y: y, x0: 35, x1: 145) < 1.5)
            #expect(abs(out.rgb(90, y).x - background.x) < 2)
        }
    }

    @Test func 打码区域以外的像素保持不变() {
        let src = makeImage(width: 200, height: 100) { stripes($0, in: CGRect(x: 0, y: 0, width: 200, height: 100)) }
        let f = Finding(kind: .phone, rect: CGRect(x: 60, y: 40, width: 80, height: 20), confidence: 1, style: .solid)
        let before = RGBAImage(src, context: context)
        let out = RGBAImage(Redactor(context: context).render(src, findings: [f]), context: context)
        // 外扩后区域约为 y 37...63；上下各留 3px 余量检查
        for y in [0, 20, 33, 67, 80, 99] {
            for x in stride(from: 0, to: 200, by: 7) { #expect(out.rgb(x, y) == before.rgb(x, y), "(\(x),\(y)) 被改动") }
        }
        #expect(out.rgb(100, 50) != before.rgb(100, 50) || out.rgb(101, 50) != before.rgb(101, 50))
    }

    @Test func 复杂背景的抹除文字退回大块像素化() {
        let src = makeImage(width: 200, height: 60) { stripes($0, in: CGRect(x: 0, y: 0, width: 200, height: 60)) }
        let f = Finding(kind: .phone, rect: CGRect(x: 40, y: 20, width: 100, height: 20), confidence: 1)
        let out = RGBAImage(Redactor(context: context).render(src, findings: [f]), context: context)
        // 块大小 ≥ 8px：同一块内的相邻像素完全相同
        #expect(out.rgb(60, 30) == out.rgb(61, 30))
    }

    @Test(arguments: MaskStyle.allCases.filter(\.ignoresSourcePixels))
    func 不读原图的效果无法还原(style: MaskStyle) {
        // 同一区域、完全不同的原图内容 → 打码后区域内像素必须一模一样
        let rect = CGRect(x: 40, y: 30, width: 120, height: 40)
        let a = makeImage(width: 200, height: 100) { stripes($0, in: rect) }
        let b = makeImage(width: 200, height: 100) { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 50, y: 35, width: 60, height: 30))
        }
        let f = Finding(kind: .phone, rect: rect, confidence: 1, style: style)
        let outA = RGBAImage(Redactor(context: context).render(a, findings: [f]), context: context)
        let outB = RGBAImage(Redactor(context: context).render(b, findings: [f]), context: context)
        for y in stride(from: 32, to: 68, by: 3) {
            for x in stride(from: 42, to: 158, by: 5) { #expect(outA.rgb(x, y) == outB.rgb(x, y), "\(style) 在 (\(x),\(y)) 泄露了原图") }
        }
        // 区域外不受影响
        #expect(outA.rgb(5, 5) == RGBAImage(a, context: context).rgb(5, 5))
    }

    @Test func 单处样式优先于全局样式() {
        let src = makeImage(width: 200, height: 60) { stripes($0, in: CGRect(x: 0, y: 0, width: 200, height: 60)) }
        var own = Finding(kind: .phone, rect: CGRect(x: 10, y: 10, width: 60, height: 30), confidence: 1)
        own.style = .solid
        let follow = Finding(kind: .phone, rect: CGRect(x: 120, y: 10, width: 60, height: 30), confidence: 1)
        var r = Redactor(context: context)
        r.fillColor = CIColor(red: 1, green: 0, blue: 0)
        let out = RGBAImage(r.render(src, findings: [own, follow], style: .rainbowBars), context: context)
        #expect(out.rgb(40, 25) == SIMD3(255, 0, 0))                // 自己指定了色块
        #expect(out.rgb(150, 25) != SIMD3(255, 0, 0))               // 跟随全局：彩虹条
    }

    @Test func 导出不带元数据() throws {
        // 造一张带 GPS、拍摄时间、机型的 JPEG，走完整条管线后检查
        let cg = CIContext().createCGImage(makeImage(width: 16, height: 16) { _ in }, from: CGRect(x: 0, y: 0, width: 16, height: 16))!
        let jpeg = NSMutableData()
        let d = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 39.9, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:25 10:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
        ] as CFDictionary)
        CGImageDestinationFinalize(d)

        let source = CIImage(data: jpeg as Data, options: [.applyOrientationProperty: true])!
        #expect(source.properties[kCGImagePropertyGPSDictionary as String] != nil)   // 原图确实带 GPS
        let redacted = Redactor(context: context).render(source, findings: [])
        let data = try Exporter.data(Redactor(context: context).makeCGImage(redacted)!, format: .png)

        let out = CGImageSourceCreateWithData(data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(out, 0, nil) as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(tiff[kCGImagePropertyTIFFModel] == nil)
    }
}
