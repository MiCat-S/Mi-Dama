// 导出：只写像素，不带任何 EXIF / GPS / 设备信息
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: Hashable, Sendable {
    /// 截图用 PNG，文字边缘不糊
    case png
    /// 照片用 HEIC，体积小
    case heic(quality: Double)
    /// 兼容性最好（部分聊天软件、网页不认 HEIC）
    case jpeg(quality: Double)

    public var utType: UTType {
        switch self {
        case .png: .png
        case .heic: .heic
        case .jpeg: .jpeg
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .heic: "heic"
        case .jpeg: "jpg"
        }
    }
}

/// 导出尺寸。缩放只发生在打码之后，所以缩小不会让打码变弱
public enum ExportSize: Codable, Hashable, Sendable {
    case original
    /// 长边不超过该像素值（不会放大）
    case maxSide(CGFloat)

    /// 再加一个长边上限（预览用：不需要比屏幕显示更大的图）
    public func capped(at side: CGFloat) -> ExportSize {
        switch self {
        case .original: .maxSide(side)
        case .maxSide(let s): .maxSide(min(s, side))
        }
    }

    public func apply(to image: CIImage) -> CIImage {
        let img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        guard case .maxSide(let side) = self else { return img }
        let longest = max(img.extent.width, img.extent.height)
        guard side > 0, longest > side else { return img }
        let scale = side / longest
        let target = CGRect(x: 0, y: 0, width: (img.extent.width * scale).rounded(), height: (img.extent.height * scale).rounded())
        // 先延展边缘再缩放，避免 Lanczos 把图外的透明像素混进最外一圈
        return img.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            .cropped(to: target)
    }
}

public enum Exporter {
    public enum Failure: Error { case encodeFailed }

    public static func data(_ image: CGImage, format: ExportFormat) throws -> Data {
        let data = NSMutableData()
        var props: [CFString: Any] = [:]
        switch format {
        case .png:
            break
        case .heic(let q), .jpeg(let q):
            props[kCGImageDestinationLossyCompressionQuality] = q
        }
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw Failure.encodeFailed
        }
        // 刻意不传原图的 properties：元数据一律不写入
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encodeFailed }
        return data as Data
    }
}

extension CIColor {
    /// "#RRGGBB"（sRGB）
    public static func fromHex(_ hex: String) -> CIColor {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return CIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255,
                       alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? .black
    }
}
