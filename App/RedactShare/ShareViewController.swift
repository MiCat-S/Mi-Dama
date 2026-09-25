// 分享扩展入口：截图后点缩略图 → 分享 → 截图打码。
// 读出分享进来的图片，交给和 App 相同的审核界面；保存后结束扩展
import RedactUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private lazy var model = ShareModel(context: extensionContext)

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareRootView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor @Observable
final class ShareModel {
    enum State: Equatable { case loading, ready, empty }

    /// 分享扩展内存上限远小于 App（常见约 120 MB），同时最多处理这么多张
    static let maxItems = 10
    /// 屏幕显示用图的长边上限；识别和导出仍用原图
    static let maxDisplaySide: CGFloat = 2048

    private(set) var items: [RedactItem] = []
    private(set) var state: State = .loading
    var message: String?
    @ObservationIgnored private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    func load() async {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            .prefix(Self.maxItems)
        for provider in providers {
            if let data = await Self.loadImageData(provider),
               let item = RedactItem(data: data, originalFilename: provider.suggestedName, maxDisplaySide: Self.maxDisplaySide) {
                items.append(item)
            }
        }
        state = items.isEmpty ? .empty : .ready
        // 串行识别，一次只有一张图的识别中间数据在内存里
        for item in items { await item.detectIfNeeded() }
    }

    /// 导出面板保存完：全部成功就结束扩展，否则显示原因
    func handleSaved(_ result: String) {
        if items.allSatisfy({ $0.phase == .saved }) { finish() } else { message = result }
    }

    func finish() {
        context?.completeRequest(returningItems: [])
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    /// 有 PNG 就优先取 PNG（「文件」等来源会提供原格式；「照片」只给转码后的 JPEG，截图判断见 RedactItem）。
    /// NSItemProvider 的回调在任意线程，这里只把结果（Data 是 Sendable）带回来
    private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        let registered = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        let type = registered.first { $0.conforms(to: .png) } ?? registered.first { $0.conforms(to: .image) } ?? .image
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
