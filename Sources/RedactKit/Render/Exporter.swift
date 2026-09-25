// 导出：只写像素，不带任何 EXIF / GPS / 设备信息
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: Sendable {
    /// 截图用 PNG，文字边缘不糊
    case png
    /// 照片用 HEIC，体积小
    case heic(quality: Double)
}

public enum Exporter {
    public enum Failure: Error { case encodeFailed }

    public static func data(_ image: CGImage, format: ExportFormat) throws -> Data {
        let data = NSMutableData()
        let type: UTType
        var props: [CFString: Any] = [:]
        switch format {
        case .png:
            type = .png
        case .heic(let q):
            type = .heic
            props[kCGImageDestinationLossyCompressionQuality] = q
        }
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure.encodeFailed
        }
        // 刻意不传原图的 properties：元数据一律不写入
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encodeFailed }
        return data as Data
    }
}
