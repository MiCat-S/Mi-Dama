// 一张待处理的图片：原图、识别结果、用户的勾选与样式
#if canImport(UIKit)
import CoreImage
import Observation
import RedactKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
public final class RedactItem: Identifiable {
    public enum Phase: Equatable {
        case detecting, ready, saved, cancelled
        case failed(String)
    }

    public let id = UUID()
    public let source: CIImage
    /// PNG 视为截图（"自动"格式下导出 PNG）；其余视为照片（导出 HEIC）
    public let isScreenshot: Bool
    public let displayImage: UIImage
    /// 原图自带的元数据（{TIFF} {Exif} {GPS} 等），仅用于"查看 EXIF"，导出时一律丢弃
    @ObservationIgnored public let metadata: [String: Any]
    /// 相册里原图的 localIdentifier（从系统选择器选图时才有），用于"保存后删除原图"
    public let assetIdentifier: String?
    public var findings: [Finding] = []
    public var phase: Phase = .detecting
    /// 全局效果；nil = 自动（按类别选默认效果）。单处在 Finding.style 里另外指定
    public var styleOverride: MaskStyle? = Preferences.style
    /// 色块、杂讯色块的颜色
    public var fillColorHex: String = Preferences.colorHex

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// - Parameter maxDisplaySide: 只限制屏幕上显示用的图（分享扩展内存紧张时用），识别和导出始终用原图
    public init?(data: Data, assetIdentifier: String? = nil, maxDisplaySide: CGFloat? = nil) {
        guard let raw = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let image = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
        let display = maxDisplaySide.map { ExportSize.maxSide($0).apply(to: image) } ?? image
        guard let cg = Self.context.createCGImage(display, from: display.extent) else { return nil }
        source = image
        isScreenshot = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        displayImage = UIImage(cgImage: cg)
        metadata = raw.properties
        self.assetIdentifier = assetIdentifier
    }

    public var size: CGSize { source.extent.size }
    public var enabledCount: Int { findings.filter(\.isEnabled).count }

    public func detect() async {
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
    }

    /// 当前勾选、样式和导出选项对应的导出任务（可跨线程传递）
    public var export: RedactedExport {
        let settings = ExportSettings.shared
        return RedactedExport(source: source, findings: findings, style: styleOverride, color: .fromHex(fillColorHex),
                              watermark: settings.activeWatermark, size: settings.size.exportSize,
                              format: settings.exportFormat(isScreenshot: isScreenshot))
    }

    /// 打码预览（后台渲染）
    public func renderPreview() async -> UIImage? {
        let export = self.export
        return await Task.detached(priority: .userInitiated) { export.render().map(UIImage.init(cgImage:)) }.value
    }
}

/// 渲染 + 编码，不带任何元数据；也用作分享面板的内容
/// @unchecked Sendable：CIImage / CIColor 不可变、可跨线程读取，但 SDK 没有标注 Sendable
public struct RedactedExport: Transferable, @unchecked Sendable {
    let source: CIImage
    let findings: [Finding]
    let style: MaskStyle?
    let color: CIColor
    let watermark: WatermarkSpec?
    let size: ExportSize
    public let format: ExportFormat

    private static let context = CIContext(options: [.cacheIntermediates: false])

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
        DataRepresentation(exportedContentType: .jpeg) { try $0.data() }
            .exportingCondition { $0.contentType == .jpeg }
        DataRepresentation(exportedContentType: .heic) { try $0.data() }
            .exportingCondition { $0.contentType == .heic }
    }
}
#endif
