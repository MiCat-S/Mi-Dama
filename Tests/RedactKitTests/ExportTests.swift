import CoreImage
import ImageIO
import Testing
@testable import RedactKit

private func solidImage(width: Int, height: Int, gray: CGFloat = 1) -> CIImage {
    CIImage(color: CIColor(red: gray, green: gray, blue: gray)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

/// 最暗像素的亮度（0–255）和亮度低于 250 的像素占比
private func darkness(_ img: RGBAImage) -> (darkest: Float, coverage: Double) {
    var darkest: Float = 255, dark = 0
    for y in 0..<img.height {
        for x in 0..<img.width {
            let c = img.rgb(x, y)
            let l = (c.x + c.y + c.z) / 3
            darkest = min(darkest, l)
            if l < 250 { dark += 1 }
        }
    }
    return (darkest, Double(dark) / Double(img.width * img.height))
}

@Suite("导出与水印")
struct ExportTests {
    let context = CIContext()

    @Test func 水印铺满整张图() {
        let spec = WatermarkSpec(text: "仅供办理测试使用", opacity: 0.5)
        let out = RGBAImage(Watermark.overlay(solidImage(width: 600, height: 400), spec: spec), context: context)
        let d = darkness(out)
        #expect(d.coverage > 0.03 && d.coverage < 0.6, "水印覆盖率 \(d.coverage)")
        // 四个角落附近都应有水印（旋转后按对角线铺满）
        let quadrants = [(0, 0), (300, 0), (0, 200), (300, 200)].map { ox, oy in
            (0..<200).contains { y in (0..<300).contains { x in
                let c = out.rgb(ox + x, oy + y); return (c.x + c.y + c.z) / 3 < 250 } }
        }
        #expect(quadrants.allSatisfy { $0 })
    }

    @Test func 空文字不加水印() {
        let src = solidImage(width: 200, height: 100)
        let out = RGBAImage(Watermark.overlay(src, spec: WatermarkSpec(text: "   ")), context: context)
        #expect(darkness(out).coverage == 0)
    }

    @Test func 透明度生效() {
        let src = solidImage(width: 400, height: 300)
        let light = darkness(RGBAImage(Watermark.overlay(src, spec: WatermarkSpec(text: "水印", opacity: 0.2)), context: context))
        let heavy = darkness(RGBAImage(Watermark.overlay(src, spec: WatermarkSpec(text: "水印", opacity: 0.8)), context: context))
        #expect(light.darkest > 190, "20% 黑色叠在白底上不应暗于约 204：\(light.darkest)")
        #expect(heavy.darkest < 80, "80% 黑色叠在白底上应接近 51：\(heavy.darkest)")
    }

    @Test func 限制长边只缩小不放大() {
        let src = solidImage(width: 400, height: 300)
        #expect(ExportSize.maxSide(200).apply(to: src).extent.size == CGSize(width: 200, height: 150))
        #expect(ExportSize.maxSide(1000).apply(to: src).extent.size == CGSize(width: 400, height: 300))
        #expect(ExportSize.original.apply(to: src).extent.size == CGSize(width: 400, height: 300))
        // 缩小后边缘不应混入透明 / 黑边
        let px = RGBAImage(ExportSize.maxSide(200).apply(to: src), context: context)
        #expect(px.rgb(0, 0).x > 250 && px.rgb(199, 149).x > 250)
    }

    @Test(arguments: [ExportFormat.jpeg(quality: 0.9), .heic(quality: 0.9), .png])
    func 各种格式都不带元数据(format: ExportFormat) throws {
        // 造一张带 GPS、拍摄时间、机型的 JPEG 作为原图
        let cg = context.createCGImage(solidImage(width: 16, height: 16, gray: 0.5), from: CGRect(x: 0, y: 0, width: 16, height: 16))!
        let jpeg = NSMutableData()
        let d = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 39.9, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:25 10:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
        ] as CFDictionary)
        CGImageDestinationFinalize(d)
        let source = CIImage(data: jpeg as Data, options: [.applyOrientationProperty: true])!

        let redactor = Redactor(context: context)
        let rendered = Watermark.overlay(redactor.render(source, findings: []), spec: WatermarkSpec(text: "测试"))
        let data = try Exporter.data(redactor.makeCGImage(rendered)!, format: format)

        let out = CGImageSourceCreateWithData(data as CFData, nil)!
        #expect(CGImageSourceGetType(out) as String? == format.utType.identifier)
        let props = CGImageSourceCopyPropertiesAtIndex(out, 0, nil) as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(tiff[kCGImagePropertyTIFFModel] == nil)
    }
}
