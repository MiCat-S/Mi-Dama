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
        case detecting, ready, saved
        case failed(String)
    }

    public let id = UUID()
    public let source: CIImage
    /// PNG 视为截图，导出 PNG；其余（照片）导出 HEIC
    public let isScreenshot: Bool
    public let displayImage: UIImage
    public var findings: [Finding] = []
    public var phase: Phase = .detecting
    /// 全局效果；nil = 自动（按类别选默认效果）。单处在 Finding.style 里另外指定
    public var styleOverride: MaskStyle? = Preferences.style
    /// 色块、杂讯色块的颜色
    public var fillColorHex: String = Preferences.colorHex

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public init?(data: Data) {
        guard let raw = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let image = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
        guard let cg = Self.context.createCGImage(image, from: image.extent) else { return nil }
        source = image
        isScreenshot = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        displayImage = UIImage(cgImage: cg)
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

    /// 当前勾选 + 样式对应的导出任务（可跨线程传递）
    public var export: RedactedExport {
        RedactedExport(source: source, findings: findings, style: styleOverride, color: .fromHex(fillColorHex),
                       format: isScreenshot ? .png : .heic(quality: 0.9))
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
    let format: ExportFormat

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public func render() -> CGImage? {
        var redactor = Redactor(context: Self.context)
        redactor.fillColor = color
        return redactor.makeCGImage(redactor.render(source, findings: findings, style: style))
    }

    public func data() throws -> Data {
        guard let cg = render() else { throw Exporter.Failure.encodeFailed }
        return try Exporter.data(cg, format: format)
    }

    public var contentType: UTType {
        if case .png = format { return .png }
        return .heic
    }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { try $0.data() }
            .exportingCondition { $0.contentType == .png }
        DataRepresentation(exportedContentType: .heic) { try $0.data() }
            .exportingCondition { $0.contentType == .heic }
    }
}
#endif
