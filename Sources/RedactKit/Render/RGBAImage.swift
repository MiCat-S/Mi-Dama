// CPU 侧像素访问：布局分析、背景色采样都用它
import CoreImage
import simd

struct RGBAImage {
    let width: Int
    let height: Int
    /// RGBA8，第 0 行是图像顶部
    private(set) var data: [UInt8]

    /// 把 CIImage（可先缩放）渲染成 RGBA8
    init(_ image: CIImage, scale: CGFloat = 1, context: CIContext) {
        var img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if scale != 1 {
            // 先延展边缘再缩放：否则 Lanczos 会把图外的透明像素混进最外一圈
            let target = CGRect(x: 0, y: 0, width: img.extent.width * scale, height: img.extent.height * scale)
            img = img.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
                .cropped(to: target)
        }
        let bounds = CGRect(x: 0, y: 0, width: floor(img.extent.width), height: floor(img.extent.height))
        width = max(1, Int(bounds.width))
        height = max(1, Int(bounds.height))
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        context.render(img.clampedToExtent(), toBitmap: &buf, rowBytes: width * 4, bounds: bounds,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        data = buf
    }

    @inline(__always)
    func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let i = (y * width + x) * 4
        return SIMD3(Float(data[i]), Float(data[i + 1]), Float(data[i + 2]))
    }

    /// 矩形外一圈（宽 `band` 像素）的中位色，以及与中位色相差不超过 `tolerance` 的像素占比。
    /// 用中位数 + 占比而不是最大偏差：JPEG 振铃、贴得很近的相邻文字只占一小部分，不该让整圈判为"不纯"
    func ringStats(around rect: CGRect, band: Int = 3, tolerance: Float = 18) -> (median: SIMD3<Float>, agreement: Float)? {
        let x0 = Int(rect.minX.rounded(.down)) - band, x1 = Int(rect.maxX.rounded(.up)) + band
        let y0 = Int(rect.minY.rounded(.down)) - band, y1 = Int(rect.maxY.rounded(.up)) + band
        var samples: [SIMD3<Float>] = []
        for y in max(0, y0)..<min(height, y1) {
            for x in max(0, x0)..<min(width, x1) {
                let inBand = x < x0 + band || x >= x1 - band || y < y0 + band || y >= y1 - band
                if inBand { samples.append(rgb(x, y)) }
            }
        }
        guard !samples.isEmpty else { return nil }
        let mid = samples.count / 2
        let median = SIMD3<Float>(samples.map(\.x).sorted()[mid], samples.map(\.y).sorted()[mid], samples.map(\.z).sorted()[mid])
        let agree = samples.filter { simd_reduce_max(simd_abs($0 - median)) <= tolerance }.count
        return (median, Float(agree) / Float(samples.count))
    }
}
