// 一张待处理的图片：原图、识别结果、用户的勾选与样式
// 创建很便宜（不解码）；显示用图、缩略图、识别都在需要时于后台完成
#if canImport(UIKit)
import CoreImage
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
    public let source: CIImage
    /// 截图（"自动"格式下导出无损 PNG）还是相机照片（导出 HEIC）
    public let isScreenshot: Bool
    /// 原图自带的元数据（{TIFF} {Exif} {GPS} 等），仅用于"查看 EXIF"，导出时一律丢弃
    @ObservationIgnored public let metadata: [String: Any]
    /// 相册里原图的 localIdentifier（从相册打开时才有），用于"保存后删除原图"
    public let assetIdentifier: String?
    /// 原文件名（用来给导出文件起名）
    public var originalFilename: String?
    public var findings: [Finding] = []
    public var phase: Phase = .pending
    /// 全局效果；nil = 自动（按类别选默认效果）。单处在 Finding.style 里另外指定
    public var styleOverride: MaskStyle? = Preferences.style
    /// 色块、杂讯色块的颜色
    public var fillColorHex: String = Preferences.colorHex
    /// 屏幕显示用图（长边不超过 maxDisplaySide），离开审核页时释放
    public private(set) var displayImage: UIImage?
    /// 列表 / 缩略图条用的小图
    public private(set) var thumbnail: UIImage?

    /// 显示用图的长边上限：截图基本不缩（iPhone 截图长边 < 3000），大照片缩小以省内存
    @ObservationIgnored let maxDisplaySide: CGFloat
    @ObservationIgnored private var detectTask: Task<Void, Never>?
    @ObservationIgnored private var displayTask: Task<Void, Never>?

    /// CIContext 线程安全，后台渲染共用一个
    private nonisolated static let renderContext = CIContext(options: [.cacheIntermediates: false])

    public init?(data: Data, assetIdentifier: String? = nil, originalFilename: String? = nil, maxDisplaySide: CGFloat = 3072) {
        guard let raw = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        source = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
        isScreenshot = ImageKind.isLikelyScreenshot(data: data, properties: raw.properties)
        metadata = raw.properties
        self.assetIdentifier = assetIdentifier
        self.originalFilename = originalFilename
        self.maxDisplaySide = maxDisplaySide
    }

    public var size: CGSize { source.extent.size }
    public var enabledCount: Int { findings.filter(\.isEnabled).count }
    public var isDetecting: Bool { phase == .pending || phase == .detecting }

    // MARK: - 图像

    public func loadThumbnail() async {
        guard thumbnail == nil else { return }
        thumbnail = await Self.render(source, maxSide: 256)
    }

    public func loadDisplayImage() async {
        if displayImage != nil { return }
        if let displayTask { return await displayTask.value }
        let task = Task { [source, maxDisplaySide] in
            self.displayImage = await Self.render(source, maxSide: maxDisplaySide)
            if self.thumbnail == nil { self.thumbnail = await Self.render(source, maxSide: 256) }
        }
        displayTask = task
        await task.value
        displayTask = nil
    }

    /// 离开审核页时调用：大图只在看的时候占内存
    public func releaseDisplayImage() {
        displayImage = nil
    }

    private nonisolated static func render(_ image: CIImage, maxSide: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let scaled = ExportSize.maxSide(maxSide).apply(to: image)
            return renderContext.createCGImage(scaled, from: scaled.extent).map(UIImage.init(cgImage:))
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
        let source = self.source
        do {
            findings = try await Task.detached(priority: .userInitiated) {
                try DetectionPipeline().detect(source)
            }.value
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
        return RedactedExport(source: source, findings: findings, style: styleOverride, color: .fromHex(fillColorHex),
                              watermark: settings.activeWatermark, size: settings.size.exportSize,
                              format: settings.exportFormat(isScreenshot: isScreenshot),
                              filename: outputBaseName)
    }

    private var outputBaseName: String {
        let base = originalFilename.map { ($0 as NSString).deletingPathExtension } ?? ""
        return base.isEmpty ? "redact-\(id.uuidString.prefix(8))" : base
    }

    /// 打码预览（后台渲染，尺寸不超过显示用图）
    public func renderPreview() async -> UIImage? {
        let full = self.export
        let export = full.sized(full.size.capped(at: maxDisplaySide))
        return await Task.detached(priority: .userInitiated) { export.render().map(UIImage.init(cgImage:)) }.value
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

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public var outputFilename: String { "\(filename)\(Self.filenameMarker)\(format.fileExtension)" }

    func sized(_ size: ExportSize) -> RedactedExport {
        RedactedExport(source: source, findings: findings, style: style, color: color, watermark: watermark,
                       size: size, format: format, filename: filename)
    }

    /// 顺序固定：先打码，再加水印，最后缩放（缩小永远不会发生在打码之前）
    public func render() -> CGImage? {
        var redactor = Redactor(context: Self.context)
        redactor.fillColor = color
        var image = redactor.render(source, findings: findings, style: style)
        if let watermark { image = Watermark.overlay(image, spec: watermark) }
        image = size.apply(to: image)
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
