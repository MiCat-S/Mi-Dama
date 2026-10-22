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
    private(set) var assets = AssetList() { didSet { stopPrefetching() } }
    var filter: Filter = .all { didSet { refetch() } }
    @ObservationIgnored let thumbnails = PHCachingImageManager()
    @ObservationIgnored private var observer: ChangeObserver?
    /// 正在预取缩略图的范围（assets 里的下标）和尺寸
    @ObservationIgnored private var prefetched: Range<Int> = 0..<0
    @ObservationIgnored private var prefetchSize: CGSize = .zero
    /// 是否本 App 导出的图，按 localIdentifier 缓存（文件名不会变）
    @ObservationIgnored private var outputFlags: [String: Bool] = [:]

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
        if isAuthorized { start() } else { assets = AssetList() }
    }

    private func start() {
        if observer == nil {
            let observer = ChangeObserver { [weak self] change in Task { @MainActor in self?.apply(change) } }
            PHPhotoLibrary.shared().register(observer)
            self.observer = observer
        }
        refetch()
    }

    private func refetch() {
        guard isAuthorized else { return }
        assets = AssetList(PHAsset.fetchAssets(with: Self.options(for: filter)))
    }

    /// 只在这次变化涉及当前列表时更新，并直接用 PhotoKit 算好的新结果，不重新查询整个相册
    private func apply(_ change: PHChange) {
        guard isAuthorized, let details = change.changeDetails(for: assets.result) else { return }
        assets = AssetList(details.fetchResultAfterChanges)
    }

    private nonisolated static func options(for filter: Filter) -> PHFetchOptions {
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

    /// 最新的一张"待打码"图片（localIdentifier）：跳过本 App 导出的图（文件名带 -redacted.）和已经保存过打码版本的原图。
    /// 逐张查文件名要同步读相册数据库，放到后台
    func latestUnprocessed() async -> String? {
        guard isAuthorized else { return nil }
        let processed = Preferences.processedAssets
        return await Task.detached(priority: .userInitiated) {
            let recent = PHAsset.fetchAssets(with: Self.options(for: .all))
            for i in 0..<min(recent.count, 30) {
                let asset = recent.object(at: i)
                if processed.contains(asset.localIdentifier) || Self.isRedactedOutput(asset) { continue }
                return asset.localIdentifier
            }
            return nil
        }.value
    }

    /// 是否本 App 导出的图（带缓存，在后台查，滚动网格时不卡主线程）
    func isOutput(_ asset: PHAsset) async -> Bool {
        let id = asset.localIdentifier
        if let cached = outputFlags[id] { return cached }
        let result = await Task.detached(priority: .userInitiated) { Self.isRedactedOutput(asset) }.value
        outputFlags[id] = result
        return result
    }

    /// 同步查询相册数据库，不要在主线程调用
    private nonisolated static func isRedactedOutput(_ asset: PHAsset) -> Bool {
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

    /// 预取和请求必须用同一组参数，才能命中 PHCachingImageManager 的缓存
    private static let thumbnailOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat   // 只回调一次
        options.resizeMode = .fast
        return options
    }()

    /// 格子滑出屏幕（任务被取消）时同时取消 PhotoKit 的请求
    func thumbnail(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let request = ThumbnailRequest(manager: thumbnails)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation) { manager, done in
                    manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill,
                                         options: Self.thumbnailOptions) { image, _ in done(image) }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// 格子出现时调用：提前解码它前后各约 10 行的缩略图，快速滑动时格子能马上出图
    func prefetchThumbnails(around index: Int, side: CGFloat) {
        let size = CGSize(width: side, height: side)
        if size != prefetchSize { stopPrefetching() }
        prefetchSize = size
        // index 可能来自刚被替换掉的旧列表（比如切换了范围），先夹到当前列表里
        let upper = min(assets.count, index + 30)
        let window = min(max(0, index - 30), upper)..<upper
        guard window != prefetched else { return }
        let old = IndexSet(integersIn: prefetched), new = IndexSet(integersIn: window)
        let added = new.subtracting(old), removed = old.subtracting(new)
        if !added.isEmpty {
            thumbnails.startCachingImages(for: assets.result.objects(at: added), targetSize: size,
                                          contentMode: .aspectFill, options: Self.thumbnailOptions)
        }
        if !removed.isEmpty {
            thumbnails.stopCachingImages(for: assets.result.objects(at: removed), targetSize: size,
                                         contentMode: .aspectFill, options: Self.thumbnailOptions)
        }
        prefetched = window
    }

    /// 列表换了（下标对不上了）或格子尺寸变了：清掉所有预取
    private func stopPrefetching() {
        thumbnails.stopCachingImagesForAllAssets()
        prefetched = 0..<0
    }

    /// 受限访问时，弹出系统界面让用户增减可访问的照片
    func presentLimitedPicker() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}

/// 让 PHFetchResult 能直接用于 ForEach（按 localIdentifier 标识，新照片进来时格子不会错位）；
/// 元素按需从 PhotoKit 取，不会一次性把整个相册读进内存
struct AssetList: RandomAccessCollection {
    let result: PHFetchResult<PHAsset>

    /// 网格里的一格：带上它在列表里的位置（预取缩略图用）
    struct Entry: Identifiable {
        let index: Int
        let asset: PHAsset
        var id: String { asset.localIdentifier }
    }

    init(_ result: PHFetchResult<PHAsset> = PHFetchResult()) {
        self.result = result
    }

    var startIndex: Int { 0 }
    var endIndex: Int { result.count }
    subscript(position: Int) -> Entry { Entry(index: position, asset: result.object(at: position)) }
}

/// PhotoKit 的回调在后台线程，这里只把变化转发出去（PHChange 只读，由主线程对照当前列表取出差异）
private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable (PHChange) -> Void

    init(_ onChange: @escaping @Sendable (PHChange) -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange(changeInstance)
    }
}

/// 一次缩略图请求：取消（可能发生在请求发出之前、之中或之后）时取消 PhotoKit 请求，
/// 并保证 continuation 只恢复一次 —— 取消后 PhotoKit 不一定还会回调
private final class ThumbnailRequest: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    init(manager: PHImageManager) {
        self.manager = manager
    }

    func start(_ continuation: CheckedContinuation<UIImage?, Never>,
               _ request: (PHImageManager, @escaping (UIImage?) -> Void) -> PHImageRequestID) {
        let alreadyCancelled = lock.withLock {
            if !cancelled { self.continuation = continuation }
            return cancelled
        }
        if alreadyCancelled { return continuation.resume(returning: nil) }
        // 命中缓存时 PhotoKit 会在 requestImage 返回前同步回调，所以这里不能持有锁
        let id = request(manager) { [self] image in finish(image) }
        let cancelNow = lock.withLock {
            requestID = id
            return cancelled
        }
        if cancelNow { manager.cancelImageRequest(id) }
    }

    func cancel() {
        let (id, pending) = lock.withLock {
            cancelled = true
            defer { continuation = nil }
            return (requestID, continuation)
        }
        if let id { manager.cancelImageRequest(id) }
        pending?.resume(returning: nil)
    }

    private func finish(_ image: UIImage?) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: image)
    }
}
