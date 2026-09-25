// 快捷指令动作「打码图片」：不打开 App，在本机识别并打码，返回打码后的图片。
// 典型用法：获取最新截图 → 打码图片 → 存储到相册 →（可选）删除照片，绑定到「轻点背面」
// 这样 App 本身不需要读取相册，删除原图也交给快捷指令自带的动作
import AppIntents
import RedactKit
import RedactUI
import UniformTypeIdentifiers

struct RedactImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "打码图片"
    static let description = IntentDescription("在本机识别并打码图片里的手机号、身份证、银行卡、人脸、二维码、聊天头像和昵称等，返回打码后的图片。全程不联网。")
    static let openAppWhenRun = false

    @Parameter(title: "图片", supportedTypeIdentifiers: ["public.image"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var images: [IntentFile]

    @Parameter(title: "效果", default: .followApp)
    var style: MaskStyleChoice

    static var parameterSummary: some ParameterSummary {
        Summary("打码 \(\.$images)，效果 \(\.$style)")
    }

    /// 读取偏好和导出设置需要在主线程；识别和编码在后台，并且一张一张来，避免后台内存峰值
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        var outputs: [IntentFile] = []
        for (index, file) in images.enumerated() {
            // 快捷指令里不显示图片，显示用图缩到最小
            guard let item = RedactItem(data: file.data, maxDisplaySide: 64) else {
                throw RedactIntentError.unreadableImage(file.filename)
            }
            await item.detect()
            if case .failed(let reason) = item.phase { throw RedactIntentError.detectionFailed(reason) }
            if let chosen = style.maskStyle(fallback: item.styleOverride) { item.styleOverride = chosen } else { item.styleOverride = nil }
            let export = item.export
            let data = try await Task.detached(priority: .userInitiated) { try export.data() }.value
            let base = (file.filename as NSString).deletingPathExtension
            let name = "\(base.isEmpty ? "image-\(index + 1)" : base)-redacted.\(export.format.fileExtension)"
            outputs.append(IntentFile(data: data, filename: name, type: export.format.utType))
        }
        return .result(value: outputs)
    }
}

enum RedactIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unreadableImage(String)
    case detectionFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unreadableImage(let name): "无法读取图片 \(name)"
        case .detectionFailed(let reason): "识别失败：\(reason)"
        }
    }
}

/// 快捷指令里可选的效果
enum MaskStyleChoice: String, AppEnum {
    case followApp, auto
    case hideText, solid, noiseBlock, pixelate, blur, rainbowBars, rainbowGrid

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "打码效果"
    static let caseDisplayRepresentations: [MaskStyleChoice: DisplayRepresentation] = [
        .followApp: "跟随 App 设置",
        .auto: "自动",
        .hideText: "抹除文字",
        .solid: "色块",
        .noiseBlock: "杂讯色块",
        .pixelate: "像素化",
        .blur: "模糊",
        .rainbowBars: "彩虹条",
        .rainbowGrid: "彩虹格",
    ]

    /// nil = 按类别自动选择
    func maskStyle(fallback appStyle: MaskStyle?) -> MaskStyle? {
        switch self {
        case .followApp: appStyle
        case .auto: nil
        default: MaskStyle(rawValue: rawValue)
        }
    }
}

struct RedactShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RedactImagesIntent(),
                    phrases: ["用\(.applicationName)打码", "\(.applicationName)打码图片"],
                    shortTitle: "打码图片",
                    systemImageName: "eye.slash")
    }
}
