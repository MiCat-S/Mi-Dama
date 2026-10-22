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
        self.init(rendering: img, bounds: CGRect(x: 0, y: 0, width: floor(img.extent.width), height: floor(img.extent.height)),
                  context: context)
    }

    /// 只渲染原图的一块：`region` 为左上原点的整数像素坐标。大图（长截图）上采样局部像素时不用整张读进内存
    init(_ image: CIImage, region: CGRect, context: CIContext) {
        let img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        self.init(rendering: img, bounds: region.flippedVertically(inHeight: img.extent.height), context: context)
    }

    /// `bounds` 为 Core Image 坐标（左下原点）
    private init(rendering img: CIImage, bounds: CGRect, context: CIContext) {
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
        let xs = max(0, x0)..<max(0, x0, min(width, x1)), ys = max(0, y0)..<max(0, y0, min(height, y1))
        let left = xs.clamped(to: x0..<(x0 + band)), right = xs.clamped(to: (x1 - band)..<x1)
        var samples: [SIMD3<Float>] = []
        for y in ys {
            if y < y0 + band || y >= y1 - band {
                for x in xs { samples.append(rgb(x, y)) }
            } else {
                // 中间的行只取左右两条边，不扫框内部
                for x in left { samples.append(rgb(x, y)) }
                for x in right { samples.append(rgb(x, y)) }
            }
        }
        guard !samples.isEmpty else { return nil }
        let mid = samples.count / 2
        let median = SIMD3<Float>(samples.map(\.x).sorted()[mid], samples.map(\.y).sorted()[mid], samples.map(\.z).sorted()[mid])
        let agree = samples.filter { simd_reduce_max(simd_abs($0 - median)) <= tolerance }.count
        return (median, Float(agree) / Float(samples.count))
    }

    /// 同 ringStats，但只渲染框附近的一小块原图：结果与在整图上算的一致，长截图上不用把整张图读进内存
    static func ringStats(of image: CIImage, around rect: CGRect, band: Int = 3, tolerance: Float = 18,
                          context: CIContext) -> (median: SIMD3<Float>, agreement: Float)? {
        let b = CGFloat(band)
        let x0 = rect.minX.rounded(.down) - b, y0 = rect.minY.rounded(.down) - b
        let region = CGRect(x: x0, y: y0, width: rect.maxX.rounded(.up) + b - x0, height: rect.maxY.rounded(.up) + b - y0)
            .intersection(CGRect(origin: .zero, size: image.extent.size)).integral
        guard !region.isEmpty else { return nil }
        return RGBAImage(image, region: region, context: context)
            .ringStats(around: rect.offsetBy(dx: -region.minX, dy: -region.minY), band: band, tolerance: tolerance)
    }
}
