// 读取相册：授权（完全 / 受限 / 拒绝）、按时间倒序列出图片、读取原图数据和缩略图、找出"最新一张待打码"
import Observation
import Photos
import RedactUI
import UIKit

@MainActor @Observable
final class PhotoLibrary {
    enum Filter: String, CaseIterable, Identifiable {
        case all, screenshots
        var id: Self { self }
        var label: String { self == .all ? "全部" : "截图" }
    }

    enum LoadError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法读取这张图片" }
    }

    private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var assets = PHFetchResult<PHAsset>()
    var filter: Filter = .all { didSet { refetch() } }
    @ObservationIgnored let thumbnails = PHCachingImageManager()
    @ObservationIgnored private var observer: ChangeObserver?

    init() {
        if isAuthorized { start() }
    }

    var isAuthorized: Bool { status == .authorized || status == .limited }

    /// 系统弹窗里用户可以选「允许完全访问 / 限制访问 / 不允许」
    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if isAuthorized { start() }
    }

    /// 从「设置」回来时权限可能变了
    func refreshStatus() {
        let new = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard new != status else { return }
        status = new
        if isAuthorized { start() } else { assets = PHFetchResult() }
    }

    private func start() {
        if observer == nil {
            let observer = ChangeObserver { [weak self] in Task { @MainActor in self?.refetch() } }
            PHPhotoLibrary.shared().register(observer)
            self.observer = observer
        }
        refetch()
    }

    private func refetch() {
        guard isAuthorized else { return }
        assets = PHAsset.fetchAssets(with: Self.options(for: filter))
    }

    private static func options(for filter: Filter) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        if filter == .screenshots {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate,
                NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue),
            ])
        }
        options.predicate = predicate
        return options
    }

    /// 最新的一张"待打码"图片：跳过本 App 导出的图（文件名带 -redacted.）和已经保存过打码版本的原图
    func latestUnprocessed() -> PHAsset? {
        guard isAuthorized else { return nil }
        let processed = Preferences.processedAssets
        let recent = PHAsset.fetchAssets(with: Self.options(for: .all))
        for i in 0..<min(recent.count, 30) {
            let asset = recent.object(at: i)
            if processed.contains(asset.localIdentifier) || Self.isRedactedOutput(asset) { continue }
            return asset
        }
        return nil
    }

    nonisolated static func isRedactedOutput(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains {
            $0.originalFilename.lowercased().contains(RedactedExport.filenameMarker)
        }
    }

    /// 原图数据（iCloud 里的图会由系统下载，这只是把用户自己的照片取回本机）
    static func loadData(for asset: PHAsset) async throws -> (data: Data, filename: String?) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: LoadError.unavailable) }
            }
        }
        return (data, filename)
    }

    func thumbnail(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat   // 只回调一次
        options.resizeMode = .fast
        let size = CGSize(width: side, height: side)
        return await withCheckedContinuation { continuation in
            thumbnails.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// 受限访问时，弹出系统界面让用户增减可访问的照片
    func presentLimitedPicker() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}

/// PhotoKit 的回调在后台线程，这里只转发一个"有变化"的信号
private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable () -> Void

    init(_ onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
