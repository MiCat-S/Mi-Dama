// 判断一张图是截图还是相机照片（决定"自动"导出格式：截图用无损 PNG，照片用 HEIC）
import Foundation
import ImageIO

public enum ImageKind {
    /// 「照片」分享出来的截图会被转码成 JPEG，只看容器格式不可靠。
    /// 相机拍的照片 EXIF 里一定有快门 / 光圈，截图没有；iOS 截图还会在 UserComment 写 "Screenshot"
    public static func isLikelyScreenshot(data: Data, properties: [String: Any]) -> Bool {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if (exif[kCGImagePropertyExifUserComment as String] as? String)?.localizedCaseInsensitiveContains("screenshot") == true {
            return true
        }
        let hasCameraExposure = exif[kCGImagePropertyExifExposureTime as String] != nil
            || exif[kCGImagePropertyExifFNumber as String] != nil
        return !hasCameraExposure
    }
}
