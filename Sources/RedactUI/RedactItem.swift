// 一张待处理的图片：原图、识别结果、用户的勾选与样式
// 创建很便宜（不解码）；显示用图、缩略图、识别都在需要时于后台完成
#if canImport(UIKit)
import CoreImage
import ImageIO
import Observation
import RedactKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
public final class RedactItem: Identifiable {
    public enum Phase: Equatable {
        /// 还没开始识别（进入审核页时才开始）
        case pending
        case detecting, ready, saved
        case failed(String)
    }

    public let id = UUID()
    /// 已按方向校正的原图。审核页显示期间带着解码缓存，离开后换成没解码过的（见 renderSource）
    @ObservationIgnored public private(set) var source: CIImage
    /// 原图文件数据（缩略图、显示用图直接从它按目标尺寸解码）
    @ObservationIgnored private let data: Data
    /// 截图（"自动"格式下导出无损 PNG）还是相机照片（导出 HEIC）
    public let isScreenshot: Bool
    /// 原图自带的元数据（{TIFF} {Exif} {GPS} 等），仅用于"查看 EXIF"，导出时一律丢弃
    @ObservationIgnored public let metadata: [String: Any]
    /// 相册里原图的 localIdentifier（从相册打开时才有），用于"保存后删除原图"
    public let assetIdentifier: String?
    /// 原文件名（用来给导出文件起名）
    public var originalFilename: String?
    /// 所有识别到 / 手动添加的区域。修改请走 edit(_:) 等方法，才能撤销
    public private(set) var findings: [Finding] = []
    /// OCR 识别出的所有文字行（"文字"工具点一下盖住一整行）
    public private(set) var textLines: [TextLine] = []
    public var phase: Phase = .pending
    /// 全局效果；nil = 自动（按类别选默认效果）。单处在 Finding.style 里另外指定
    public private(set) var styleOverride: MaskStyle? = Preferences.style
    /// 色块、杂讯色块的颜色
    public var fillColorHex: String = Preferences.colorHex
    /// 屏幕显示用图（长边不超过 maxDisplaySide），离开审核页时释放
    public private(set) var displayImage: UIImage?
    /// 列表 / 缩略图条用的小图
    public private(set) var thumbnail: UIImage?

    /// 显示用图的长边上限：截图基本不缩（iPhone 截图长边 < 3000），大照片缩小以省内存
    @ObservationIgnored let maxDisplaySide: CGFloat
    @ObservationIgnored private var detectTask: Task<Void, Never>?
    private var history = EditHistory<EditState>()
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    /// 正在显示这张图的审核页数量（loadDisplayImage / releaseDisplayImage 成对调用），归零时释放显示用图
    @ObservationIgnored private var displayUsers = 0
    /// 正在跑的预览渲染，以及排在它后面的下一次
    @ObservationIgnored private var previewTask: Task<UIImage?, Never>?
    @ObservationIgnored private var queuedPreview: Task<UIImage?, Never>?

    public init?(data: Data, assetIdentifier: String? = nil, originalFilename: String? = nil, maxDisplaySide: CGFloat = 3072) {
        guard let raw = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        self.data = data
        source = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
        isScreenshot = ImageKind.isLikelyScreenshot(data: data, properties: raw.properties)
        metadata = raw.properties
        self.assetIdentifier = assetIdentifier
        self.originalFilename = originalFilename
        self.maxDisplaySide = maxDisplaySide
    }

    private nonisolated static func makeSource(_ data: Data) -> CIImage? {
        guard let raw = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        return raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
    }

    /// 识别、预览、导出用的原图。CIImage(data:) 第一次渲染时，ImageIO 会把整张图解码后缓存在这个 CIImage 里
    /// （长截图约 80 MB），它活多久就占多久。审核页显示期间共用 source 这一份：没有这份缓存，长截图每次渲染都要
    /// 重新解码好几秒。不在显示时每次用一个新的，用完就释放，解码缓存不会跟着 ItemStore 里的缓存一直留着
    private var renderSource: CIImage {
        displayUsers > 0 ? source : Self.makeSource(data) ?? source
    }

    public var size: CGSize { source.extent.size }
    public var enabledCount: Int { findings.filter(\.isEnabled).count }

    /// 各类别的数量和是否有勾选；数量相同时按类别固定顺序，避免点选后标签跳来跳去
    public var kindCounts: [(kind: FindingKind, count: Int, enabled: Bool)] {
        Dictionary(grouping: findings, by: \.kind)
            .map { ($0.key, $0.value.count, $0.value.contains(where: \.isEnabled)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.kind.rawValue < $1.kind.rawValue }
    }

    // MARK: - 编辑（全部可撤销）

    /// 撤销 / 重做覆盖的内容：所有区域的勾选、样式、位置，以及全局效果
    struct EditState: Equatable {
        var findings: [Finding]
        var style: MaskStyle?
    }

    private var editState: EditState { EditState(findings: findings, style: styleOverride) }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    /// 一次可撤销的编辑
    public func edit(_ change: (inout [Finding]) -> Void) {
        let before = editState
        change(&findings)
        history.record(before: before, after: editState)
    }

    public func undo() {
        if let state = history.undo(current: editState) { apply(state) }
    }

    public func redo() {
        if let state = history.redo(current: editState) { apply(state) }
    }

    private func apply(_ state: EditState) {
        findings = state.findings
        styleOverride = state.style
    }

    /// 按 id 修改一处
    public func updateFinding(_ id: UUID, _ change: (inout Finding) -> Void) {
        edit { findings in
            if let i = findings.firstIndex(where: { $0.id == id }) { change(&findings[i]) }
        }
    }

    /// 整个类别一起开 / 关
    public func setFindings(of kind: FindingKind, enabled: Bool) {
        edit { findings in
            for i in findings.indices where findings[i].kind == kind { findings[i].isEnabled = enabled }
        }
    }

    public func addFinding(_ finding: Finding) {
        edit { $0.append(finding) }
    }

    public func removeFinding(_ id: UUID) {
        edit { $0.removeAll { $0.id == id } }
    }

    /// 全局效果
    /// - Parameter remember: 记住作为下次的默认（快捷指令里临时指定效果时传 false）
    public func setStyle(_ style: MaskStyle?, remember: Bool = true) {
        let before = editState
        styleOverride = style
        if remember { Preferences.style = style }
        history.record(before: before, after: editState)
    }

    /// 自动识别出的区域（手动添加的不算）是否有任何一处在打码
    public var isAutoRedactionOn: Bool {
        findings.contains { $0.kind != .manual && $0.isEnabled }
    }

    /// 自动打码总开关：关 = 所有自动识别的区域都不打码；开 = 恢复默认勾选（置信度足够的）
    public func setAutoRedaction(_ on: Bool) {
        edit { findings in
            for i in findings.indices where findings[i].kind != .manual {
                findings[i].isEnabled = on && findings[i].confidence >= 0.5
            }
        }
    }

    /// 文字工具：点中的那一行已有整行打码就开 / 关它，否则加一个盖住整行的区域
    public func toggleTextLine(at point: CGPoint) {
        guard let line = textLines.filter({ $0.rect.insetBy(dx: -4, dy: -4).contains(point) })
            .min(by: { $0.rect.area < $1.rect.area }) else { return }
        if let existing = findings.first(where: { $0.kind == .manual && $0.rect.iou(line.rect) > 0.8 }) {
            updateFinding(existing.id) { $0.isEnabled.toggle() }
        } else {
            addFinding(Finding(kind: .manual, rect: line.rect, confidence: 1, text: line.text))
        }
    }

    public var isDetecting: Bool { phase == .pending || phase == .detecting }

    // MARK: - 图像

    public func loadThumbnail() async {
        guard thumbnail == nil else { return }
        thumbnail = await Self.decode(data, maxSide: 256)
    }

    /// 进入审核页时调用，与 releaseDisplayImage 成对
    public func loadDisplayImage() async {
        displayUsers += 1
        if displayImage != nil { return }
        if let displayTask { return await displayTask.value }
        let task = Task { [data, maxDisplaySide] in
            let image = await Self.decode(data, maxSide: maxDisplaySide)
            // 解码期间审核页已经关掉：不留住这张大图（否则它会一直跟着 ItemStore 里的缓存）
            if self.displayUsers > 0 { self.displayImage = image }
            if self.thumbnail == nil { self.thumbnail = await Self.decode(data, maxSide: 256) }
        }
        displayTask = task
        await task.value
        displayTask = nil
    }

    /// 离开审核页时调用：大图只在看的时候占内存
    public func releaseDisplayImage() {
        displayUsers -= 1
        guard displayUsers <= 0 else { return }
        displayImage = nil
        // 连同原图的解码缓存一起丢掉（见 renderSource）；还在跑的识别、渲染拿着旧的那份，用完自然释放
        source = Self.makeSource(data) ?? source
    }

    /// 按目标尺寸解码：ImageIO 对 JPEG / HEIC 可以边解码边缩小，比完整解码后再缩放快、省内存；
    /// WithTransform 按 EXIF 方向转正，和 source 一致。ImageIO 读不了的格式退回 Core Image
    private nonisolated static func decode(_ data: Data, maxSide: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
                return UIImage(cgImage: cg)
            }
            guard let image = Self.makeSource(data) else { return nil }
            let scaled = ExportSize.maxSide(maxSide).apply(to: image)
            return RenderContext.shared.createCGImage(scaled, from: scaled.extent).map(UIImage.init(cgImage:))
        }.value
    }

    // MARK: - 识别

    /// 还没识别过就开始识别；正在识别则等它完成（多处同时调用只会识别一次）
    public func detectIfNeeded() async {
        if let detectTask { return await detectTask.value }
        guard phase == .pending else { return }
        let task = Task { await self.runDetection() }
        detectTask = task
        await task.value
    }

    /// 强制重新识别
    public func detect() async {
        if let detectTask { await detectTask.value }
        phase = .pending
        await detectIfNeeded()
    }

    private func runDetection() async {
        phase = .detecting
        let source = renderSource
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try DetectionPipeline().analyze(source)
            }.value
            // 识别结果是起点，不算一次编辑
            findings = result.findings
            textLines = result.textLines
            history.reset()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
        detectTask = nil
    }

    // MARK: - 导出

    /// 当前勾选、样式和导出选项对应的导出任务（可跨线程传递）
    public var export: RedactedExport {
        let settings = ExportSettings.shared
        return RedactedExport(source: renderSource, findings: findings, style: styleOverride, color: .fromHex(fillColorHex),
                              watermark: settings.activeWatermark, size: settings.size.exportSize,
                              format: settings.exportFormat(isScreenshot: isScreenshot),
                              filename: outputBaseName)
    }

    private var outputBaseName: String {
        let base = originalFilename.map { ($0 as NSString).deletingPathExtension } ?? ""
        return base.isEmpty ? "redact-\(id.uuidString.prefix(8))" : base
    }

    /// 打码预览（后台渲染，尺寸不超过显示用图）。同一时间只渲染一张：渲染中又有修改就排一次，
    /// 排队的那次开始时才读取状态，期间再来的请求都共用它 —— 连点、拖取色器时不会堆起一串全尺寸渲染
    public func renderPreview() async -> UIImage? {
        if let queuedPreview { return await queuedPreview.value }
        guard let running = previewTask else { return await startPreview() }
        let next = Task<UIImage?, Never> {
            _ = await running.value
            self.queuedPreview = nil
            return await self.startPreview()
        }
        queuedPreview = next
        return await next.value
    }

    private func startPreview() async -> UIImage? {
        let full = self.export
        let export = full.sized(full.size.capped(at: maxDisplaySide))
        let task = Task.detached(priority: .userInitiated) { export.render().map(UIImage.init(cgImage:)) }
        previewTask = task
        let image = await task.value
        if previewTask == task { previewTask = nil }
        return image
    }
}

/// 渲染 + 编码，不带任何元数据；也用作分享面板的内容
/// @unchecked Sendable：CIImage / CIColor 不可变、可跨线程读取，但 SDK 没有标注 Sendable
public struct RedactedExport: Transferable, @unchecked Sendable {
    /// 本 App 输出的文件名里都带这个标记：相册里据此认出输出图，打开 App 时不会再自动进入它
    public static let filenameMarker = "-redacted."

    let source: CIImage
    let findings: [Finding]
    let style: MaskStyle?
    let color: CIColor
    let watermark: WatermarkSpec?
    let size: ExportSize
    public let format: ExportFormat
    let filename: String

    private static let context = RenderContext.shared

    public var outputFilename: String { "\(filename)\(Self.filenameMarker)\(format.fileExtension)" }

    func sized(_ size: ExportSize) -> RedactedExport {
        RedactedExport(source: source, findings: findings, style: style, color: color, watermark: watermark,
                       size: size, format: format, filename: filename)
    }

    /// 顺序固定：先打码，再缩放（缩小永远不会发生在打码之前），最后在输出尺寸上加水印。
    /// 水印字号、间距都按图片宽度换算，画在输出尺寸上效果一样，还不用按原图尺寸开一整块位图
    public func render() -> CGImage? {
        var redactor = Redactor(context: Self.context)
        redactor.fillColor = color
        var image = size.apply(to: redactor.render(source, findings: findings, style: style))
        if let watermark { image = Watermark.overlay(image, spec: watermark) }
        return redactor.makeCGImage(image)
    }

    public func data() throws -> Data {
        guard let cg = render() else { throw Exporter.Failure.encodeFailed }
        return try Exporter.data(cg, format: format)
    }

    public var contentType: UTType { format.utType }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { try $0.data() }
            .exportingCondition { $0.contentType == .png }
            .suggestedFileName { $0.outputFilename }
        DataRepresentation(exportedContentType: .jpeg) { try $0.data() }
            .exportingCondition { $0.contentType == .jpeg }
            .suggestedFileName { $0.outputFilename }
        DataRepresentation(exportedContentType: .heic) { try $0.data() }
            .exportingCondition { $0.contentType == .heic }
            .suggestedFileName { $0.outputFilename }
    }
}
#endif
