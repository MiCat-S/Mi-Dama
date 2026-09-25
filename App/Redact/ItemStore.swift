// 已打开过的图片（识别结果、勾选、样式）在本次运行内保留，来回切换不用重新识别
// key：相册图片用 localIdentifier，系统选择器选来的图用 "picked:UUID"
import Photos
import RedactUI

@MainActor @Observable
final class ItemStore {
    /// 最多保留这么多张（每张只留压缩后的原图数据和识别结果，大图在离开审核页时已释放）
    private static let capacity = 40

    @ObservationIgnored private var items: [String: RedactItem] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var loading: [String: Task<RedactItem?, Never>] = [:]

    func cached(_ key: String) -> RedactItem? { items[key] }

    func register(_ item: RedactItem, key: String) {
        items[key] = item
        touch(key)
    }

    func item(for key: String) async -> RedactItem? {
        if let item = items[key] { return item }
        if let task = loading[key] { return await task.value }
        let task = Task { () -> RedactItem? in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [key], options: nil).firstObject,
                  let (data, filename) = try? await PhotoLibrary.loadData(for: asset) else { return nil }
            return RedactItem(data: data, assetIdentifier: key, originalFilename: filename)
        }
        loading[key] = task
        let item = await task.value
        loading[key] = nil
        if let item { register(item, key: key) }
        return item
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.capacity { items[order.removeFirst()] = nil }
    }
}
