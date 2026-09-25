// 相册读写：保存只申请"仅添加"权限；只有用户开启"保存后删除原图"时才申请完整访问
#if canImport(UIKit)
import Photos

public enum PhotoSaver {
    public enum SaveError: LocalizedError {
        case denied
        public var errorDescription: String? { "没有相册写入权限，请在「设置 › 隐私 › 照片」中允许添加照片" }
    }

    public enum DeleteError: LocalizedError {
        case denied
        /// 受限访问（只授权了部分照片）或原图已不存在
        case notAccessible
        public var errorDescription: String? {
            switch self {
            case .denied:
                "没有照片访问权限，原图未删除。可在「设置 › 截图打码 › 照片」中改为「完全访问」。"
            case .notAccessible:
                "相册访问受限，无法删除原图。可在「设置 › 截图打码 › 照片」改为「完全访问」，或在快捷指令里用「删除照片」动作。"
            }
        }
    }

    public enum DeleteOutcome: Sendable {
        /// missing：因受限访问或已被删而找不到的数量
        case deleted(count: Int, missing: Int)
        /// 用户在系统确认框里点了"不允许"
        case cancelled
    }

    public static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    /// 一次性删除多张原图（系统只弹一次确认框），删除的照片会进「最近删除」
    public static func deleteOriginals(_ identifiers: [String]) async throws -> DeleteOutcome {
        guard !identifiers.isEmpty else { return .deleted(count: 0, missing: 0) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw DeleteError.denied }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).count
        guard found > 0 else { throw DeleteError.notAccessible }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil))
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return .cancelled
        }
        return .deleted(count: found, missing: identifiers.count - found)
    }

    /// 保存结果的提示文案
    public static func summary(saved: Int, deletion: Result<DeleteOutcome, Error>?) -> String {
        let head = saved == 1 ? "已保存到相册" : "已保存 \(saved) 张到相册"
        switch deletion {
        case nil:
            return head
        case .success(.deleted(let count, let missing)):
            if count == 0 { return head }
            return missing == 0 ? "\(head)，原图已删除" : "\(head)，删除了 \(count) 张原图（\(missing) 张无法访问）"
        case .success(.cancelled):
            return "\(head)，原图未删除"
        case .failure(let error):
            return "\(head)。\(error.localizedDescription)"
        }
    }
}
#endif
