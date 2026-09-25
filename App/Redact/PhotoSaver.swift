// 保存到相册：只申请"仅添加"权限，读不到用户的任何照片
import Photos

enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "没有相册写入权限，请在「设置 › 隐私 › 照片」中允许添加照片" }
    }

    static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}
