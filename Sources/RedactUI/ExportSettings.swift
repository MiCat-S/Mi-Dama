// 导出选项：对所有图片生效（批量保存时行为一致），改动即持久化
#if canImport(UIKit)
import Foundation
import Observation
import RedactKit

@MainActor @Observable
public final class ExportSettings {
    public static let shared = ExportSettings()

    public enum FormatChoice: String, CaseIterable, Identifiable, Sendable {
        case auto, png, jpeg, heic
        public var id: Self { self }
        public var label: String {
            switch self {
            case .auto: "自动（截图 PNG，照片 HEIC）"
            case .png: "PNG"
            case .jpeg: "JPEG"
            case .heic: "HEIC"
            }
        }
    }

    public enum SizeChoice: String, CaseIterable, Identifiable, Sendable {
        case original, side2560, side1920, side1280
        public var id: Self { self }
        public var label: String {
            switch self {
            case .original: "原尺寸"
            case .side2560: "长边 2560"
            case .side1920: "长边 1920"
            case .side1280: "长边 1280"
            }
        }
        public var exportSize: ExportSize {
            switch self {
            case .original: .original
            case .side2560: .maxSide(2560)
            case .side1920: .maxSide(1920)
            case .side1280: .maxSide(1280)
            }
        }
    }

    public var format: FormatChoice { didSet { defaults.set(format.rawValue, forKey: Key.format) } }
    public var size: SizeChoice { didSet { defaults.set(size.rawValue, forKey: Key.size) } }
    public var watermarkEnabled: Bool { didSet { defaults.set(watermarkEnabled, forKey: Key.watermarkEnabled) } }
    public var watermark: WatermarkSpec {
        didSet { defaults.set(try? JSONEncoder().encode(watermark), forKey: Key.watermark) }
    }
    /// 保存打码图后删除相册里的原图（默认关闭）
    public var deleteOriginal: Bool { didSet { defaults.set(deleteOriginal, forKey: Key.deleteOriginal) } }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let format = "export.format", size = "export.size", deleteOriginal = "export.deleteOriginal"
        static let watermarkEnabled = "export.watermarkEnabled", watermark = "export.watermark"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        format = FormatChoice(rawValue: defaults.string(forKey: Key.format) ?? "") ?? .auto
        size = SizeChoice(rawValue: defaults.string(forKey: Key.size) ?? "") ?? .original
        watermarkEnabled = defaults.bool(forKey: Key.watermarkEnabled)
        watermark = defaults.data(forKey: Key.watermark).flatMap { try? JSONDecoder().decode(WatermarkSpec.self, from: $0) }
            ?? WatermarkSpec()
        deleteOriginal = defaults.bool(forKey: Key.deleteOriginal)
    }

    public func exportFormat(isScreenshot: Bool) -> ExportFormat {
        switch format {
        case .auto: isScreenshot ? .png : .heic(quality: 0.9)
        case .png: .png
        case .jpeg: .jpeg(quality: 0.9)
        case .heic: .heic(quality: 0.9)
        }
    }

    /// 实际要画的水印；关闭或没填文字时为 nil
    public var activeWatermark: WatermarkSpec? {
        watermarkEnabled && !watermark.isEmpty ? watermark : nil
    }
}
#endif
