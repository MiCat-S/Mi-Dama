// 一张待处理的图片：原图、识别结果、用户的勾选与样式
// 创建很便宜（不解码）；显示用图、缩略图、识别都在需要时于后台完成
// 也可以是几张图拼成的一张（拼图）：识别逐张做，结果换算到拼图上；布局可以改，也能撤销
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

    /// 图片从哪来：一份图片文件，或几张图片文件按某个布局拼成一张（可跨线程传递，用来重新生成原图）
    private enum Origin: Sendable {
        case file(Data)
        case merged([Data], Composition)
    }

    public let id = UUID()
    /// 已按方向校正的原图。审核页显示期间带着解码缓存，离开后换成没解码过的（见 renderSource）
    @ObservationIgnored public private(set) var source: CIImage
    /// 原图文件数据（缩略图、显示用图直接从它按目标尺寸解码）
    @ObservationIgnored private var origin: Origin
    /// 截图（"自动"格式下导出无损 PNG）还是相机照片（导出 HEIC）；拼图：每张都是截图才算截图
    public let isScreenshot: Bool
    /// 原图自带的元数据（{TIFF} {Exif} {GPS} 等），仅用于"查看 EXIF"，导出时一律丢弃；拼图没有
    @ObservationIgnored public let metadata: [String: Any]
    /// 相册里原图的 localIdentifier（从相册打开时才有），用于"保存后删除原图"；拼图是每张原图的
    public let assetIdentifiers: [String]
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

    // MARK: 拼图

    /// 拼成这张图的各张图（按输入顺序）；不是拼图时为空。识别结果取自它们
    @ObservationIgnored private let parts: [RedactItem]
    @ObservationIgnored private var composition: Composition?
    /// 拼图当前显示的布局；不是拼图时为 nil
    public private(set) var mergeLayout: MergeLayout?
    /// 正在切换去的布局（布局面板显示它，连点时不会被还没切完的旧布局盖掉）；没在切换时等于 mergeLayout
    public private(set) var targetLayout: MergeLayout?

    public var isMerged: Bool { !parts.isEmpty }
    public var isChangingLayout: Bool { targetLayout != mergeLayout }

    private init(origin: Origin, source: CIImage, parts: [RedactItem], composition: Composition?, isScreenshot: Bool,
                 metadata: [String: Any], assetIdentifiers: [String], originalFilename: String?, maxDisplaySide: CGFloat) {
        self.origin = origin
        self.source = source
        self.parts = parts
        self.composition = composition
        mergeLayout = composition?.layout
        targetLayout = composition?.layout
        self.isScreenshot = isScreenshot
        self.metadata = metadata
        self.assetIdentifiers = assetIdentifiers
        self.originalFilename = originalFilename
        self.maxDisplaySide = maxDisplaySide
    }

    public convenience init?(data: Data, assetIdentifier: String? = nil, originalFilename: String? = nil, maxDisplaySide: CGFloat = 3072) {
        guard let raw = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        self.init(origin: .file(data),
                  source: raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY)),
                  parts: [], composition: nil,
                  isScreenshot: ImageKind.isLikelyScreenshot(data: data, properties: raw.properties),
                  metadata: raw.properties, assetIdentifiers: assetIdentifier.map { [$0] } ?? [],
                  originalFilename: originalFilename, maxDisplaySide: maxDisplaySide)
    }

    /// 把几张图拼成一张。各张图已经识别过（或者在单张里改过勾选、加过框）的，结果直接带过来
    /// - Parameter layout: nil = 上次用过的布局，没用过就按图片形状选默认布局
    public convenience init?(merging parts: [RedactItem], layout: MergeLayout? = nil) {
        let files = parts.compactMap { item -> Data? in
            if case .file(let data) = item.origin { return data }
            return nil
        }
        guard parts.count >= 2, files.count == parts.count else { return nil }
        let sizes = parts.map(\.size)
        let composition = Composition(partSizes: sizes, layout: layout ?? Preferences.mergeLayout(for: sizes))
        let origin = Origin.merged(files, composition)
        guard let source = Self.makeSource(origin) else { return nil }
        let first = parts[0].originalFilename.map { ($0 as NSString).deletingPathExtension } ?? ""
        self.init(origin: origin, source: source, parts: parts, composition: composition,
                  isScreenshot: parts.allSatisfy(\.isScreenshot), metadata: [:],
                  assetIdentifiers: parts.flatMap(\.assetIdentifiers),
                  originalFilename: "merged-\(first.isEmpty ? String(UUID().uuidString.prefix(8)) : first)",
                  maxDisplaySide: parts.map(\.maxDisplaySide).max() ?? 3072)
    }

    private nonisolated static func makeSource(_ data: Data) -> CIImage? {
        guard let raw = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        return raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
    }

    private nonisolated static func makeSource(_ origin: Origin) -> CIImage? {
        switch origin {
        case .file(let data):
            return makeSource(data)
        case .merged(let files, let composition):
            let images = files.compactMap { makeSource($0) }
            return images.count == files.count ? composition.compose(images) : nil
        }
    }

    /// 识别、预览、导出用的原图。CIImage(data:) 第一次渲染时，ImageIO 会把整张图解码后缓存在这个 CIImage 里
    /// （长截图约 80 MB），它活多久就占多久。审核页显示期间共用 source 这一份：没有这份缓存，长截图每次渲染都要
    /// 重新解码好几秒。不在显示时每次用一个新的，用完就释放，解码缓存不会跟着 ItemStore 里的缓存一直留着
    private var renderSource: CIImage {
        displayUsers > 0 ? source : Self.makeSource(origin) ?? source
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

    /// 撤销 / 重做覆盖的内容：所有区域的勾选、样式、位置，全局效果，以及拼图布局（区域坐标跟着布局走，必须一起记）
    struct EditState: Equatable {
        var findings: [Finding]
        var style: MaskStyle?
        var layout: MergeLayout?
    }

    private var editState: EditState { EditState(findings: findings, style: styleOverride, layout: mergeLayout) }

    /// 切换布局期间不能撤销：切换完成前区域还是旧布局的坐标
    public var canUndo: Bool { history.canUndo && !isChangingLayout }
    public var canRedo: Bool { history.canRedo && !isChangingLayout }

    /// 一次可撤销的编辑
    public func edit(_ change: (inout [Finding]) -> Void) {
        let before = editState
        change(&findings)
        history.record(before: before, after: editState)
    }

    public func undo() {
        guard !isChangingLayout, let state = history.undo(current: editState) else { return }
        apply(state)
    }

    public func redo() {
        guard !isChangingLayout, let state = history.redo(current: editState) else { return }
        apply(state)
    }

    private func apply(_ state: EditState) {
        guard let layout = state.layout, layout != mergeLayout, let composition else {
            findings = state.findings
            styleOverride = state.style
            return
        }
        // 撤销 / 重做到另一种布局：和换布局一样，新布局渲染好再一起换上
        targetLayout = layout
        Task { await switchLayout(to: state, composition: Composition(partSizes: composition.partSizes, layout: layout)) }
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
        thumbnail = await Self.decode(origin, maxSide: 256)
    }

    private func isCurrent(_ other: Origin) -> Bool {
        if case .merged(_, let c) = other { return c == composition }
        return true
    }

    /// 进入审核页时调用，与 releaseDisplayImage 成对
    public func loadDisplayImage() async {
        displayUsers += 1
        if displayImage != nil { return }
        if let displayTask { return await displayTask.value }
        let task = Task { [origin, maxDisplaySide] in
            let image = await Self.decode(origin, maxSide: maxDisplaySide)
            // 解码期间审核页已经关掉：不留住这张大图（否则它会一直跟着 ItemStore 里的缓存）；
            // 解码期间换了拼图布局：这张已经过时（换布局时已经带上了新的）
            if self.displayUsers > 0, self.isCurrent(origin) { self.displayImage = image }
            if self.thumbnail == nil { self.thumbnail = await Self.decode(origin, maxSide: 256) }
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
        preview = nil
        // 连同原图的解码缓存一起丢掉（见 renderSource）；还在跑的识别、渲染拿着旧的那份，用完自然释放
        source = Self.makeSource(origin) ?? source
    }

    /// 按目标尺寸解码：ImageIO 对 JPEG / HEIC 可以边解码边缩小，比完整解码后再缩放快、省内存；
    /// WithTransform 按 EXIF 方向转正，和 source 一致。ImageIO 读不了的格式退回 Core Image
    private nonisolated static func decode(_ origin: Origin, maxSide: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            if case .file(let data) = origin {
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
            }
            return Self.makeSource(origin).flatMap { scaledImage($0, maxSide: maxSide) }
        }.value
    }

    private nonisolated static func scaledImage(_ image: CIImage, maxSide: CGFloat) -> UIImage? {
        let scaled = ExportSize.maxSide(maxSide).apply(to: image)
        return RenderContext.shared.createCGImage(scaled, from: scaled.extent).map(UIImage.init(cgImage:))
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
        if isMerged { return await runMergedDetection() }
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

    /// 拼图不识别拼好的大图（聊天布局分析找"贴着左右边缘的头像""最上面的标题"，拼起来就不成立了），
    /// 而是逐张识别（已经识别过的直接用），再按位置换算过来。某张失败时保留其余的结果，并提示失败
    private func runMergedDetection() async {
        var failure: String?
        for part in parts {
            await part.detectIfNeeded()
            if case .failed(let reason) = part.phase, failure == nil { failure = reason }
        }
        if let composition {
            findings = composition.findings(from: parts.map(\.findings))
            textLines = composition.textLines(from: parts.map(\.textLines))
        }
        history.reset()
        phase = failure.map { .failed($0) } ?? .ready
        detectTask = nil
    }

    // MARK: - 拼图布局

    /// 换布局。区域按所在的那张图换算到新位置（跨接缝的拆开），可撤销。
    /// 新布局的显示用图和打码预览先在后台渲染好，再和区域一起换上：画面不会先变形、也不会闪出没打码的原图。
    /// 连续点的时候只切到最后选的那个
    public func setMergeLayout(_ layout: MergeLayout) {
        guard let composition, !isDetecting else { return }
        let wasChanging = isChangingLayout
        targetLayout = Composition(partSizes: composition.partSizes, layout: layout).layout
        guard !wasChanging else { return }
        Task {
            while let target = targetLayout, target != mergeLayout, let current = self.composition {
                let next = Composition(partSizes: current.partSizes, layout: target)
                let before = editState
                let after = EditState(findings: current.remap(findings, to: next), style: styleOverride, layout: next.layout)
                await switchLayout(to: after, composition: next)
                history.record(before: before, after: editState)
            }
        }
    }

    private func switchLayout(to state: EditState, composition next: Composition) async {
        guard case .merged(let files, _) = origin else { return }
        let newOrigin = Origin.merged(files, next)
        guard let newSource = Self.makeSource(newOrigin) else {
            targetLayout = mergeLayout
            return
        }
        let showing = displayUsers > 0
        var display: UIImage?, image: UIImage?
        if showing {
            let export = makeExport(source: newSource, findings: state.findings, style: state.style)
            let previewExport = export.sized(export.size.capped(at: maxDisplaySide))
            (display, image) = await Task.detached(priority: .userInitiated) { [maxDisplaySide] in
                (Self.scaledImage(newSource, maxSide: maxDisplaySide), previewExport.render().map(UIImage.init(cgImage:)))
            }.value
        }
        // 下面一次性换上（中间没有 await，界面只会看到切换前和切换后）
        origin = newOrigin
        composition = next
        // 渲染期间离开了审核页：newSource 带着刚才的解码缓存，换成没解码过的（见 renderSource）
        source = displayUsers > 0 ? newSource : Self.makeSource(newOrigin) ?? newSource
        textLines = next.textLines(from: parts.map(\.textLines))
        findings = state.findings
        styleOverride = state.style
        mergeLayout = next.layout
        thumbnail = nil
        if showing, displayUsers > 0 {
            displayImage = display
            preview = image
        }
    }

    // MARK: - 导出

    /// 当前勾选、样式和导出选项对应的导出任务（可跨线程传递）
    public var export: RedactedExport {
        makeExport(source: renderSource, findings: findings, style: styleOverride)
    }

    private func makeExport(source: CIImage, findings: [Finding], style: MaskStyle?) -> RedactedExport {
        let settings = ExportSettings.shared
        return RedactedExport(source: source, findings: findings, style: style, color: .fromHex(fillColorHex),
                              watermark: settings.activeWatermark, size: settings.size.exportSize,
                              format: settings.exportFormat(isScreenshot: isScreenshot),
                              filename: outputBaseName)
    }

    private var outputBaseName: String {
        let base = originalFilename.map { ($0 as NSString).deletingPathExtension } ?? ""
        return base.isEmpty ? "redact-\(id.uuidString.prefix(8))" : base
    }

    /// 审核页显示的打码预览（renderPreview 的结果）；换拼图布局时和新布局一起换上。离开审核页时释放
    public private(set) var preview: UIImage?

    /// 打码预览（后台渲染，尺寸不超过显示用图）。同一时间只渲染一张：渲染中又有修改就排一次，
    /// 排队的那次开始时才读取状态，期间再来的请求都共用它 —— 连点、拖取色器时不会堆起一串全尺寸渲染。
    /// 依次渲染、依次完成，所以最后完成的总是最新的状态；审核页显示期间结果同时存进 preview
    @discardableResult
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
        let layout = mergeLayout
        let export = full.sized(full.size.capped(at: maxDisplaySide))
        let task = Task.detached(priority: .userInitiated) { export.render().map(UIImage.init(cgImage:)) }
        previewTask = task
        let image = await task.value
        if previewTask == task { previewTask = nil }
        // 渲染期间换了布局：这张是旧布局的，不能盖掉换布局时带上的新预览
        if displayUsers > 0, layout == mergeLayout { preview = image }
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
