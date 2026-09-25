// 导出选项：格式、大小、浮水印、查看原图 EXIF、保存后删除原图
#if canImport(UIKit)
import RedactKit
import SwiftUI

struct ExportOptionsSheet: View {
    @Bindable var settings: ExportSettings
    let item: RedactItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("格式", selection: $settings.format) {
                        ForEach(ExportSettings.FormatChoice.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("大小", selection: $settings.size) {
                        ForEach(ExportSettings.SizeChoice.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    let out = settings.size.exportSize.apply(to: item.source).extent.size
                    Text("这张图将导出为 \(Int(out.width)) × \(Int(out.height))，\(settings.exportFormat(isScreenshot: item.isScreenshot).fileExtension.uppercased())。缩放在打码之后进行，不会削弱打码。")
                }

                Section {
                    Toggle("浮水印", isOn: $settings.watermarkEnabled)
                    if settings.watermarkEnabled {
                        TextField("水印文字，例如：仅供办理 XX 业务使用", text: $settings.watermark.text, axis: .vertical)
                        slider("大小", value: $settings.watermark.fontScale, in: 0.02...0.1, format: { "\(Int($0 * 1000))" })
                        slider("不透明度", value: $settings.watermark.opacity, in: 0.05...0.8, format: { "\(Int($0 * 100))%" })
                        slider("角度", value: $settings.watermark.angleDegrees, in: -60...60, format: { "\(Int($0))°" })
                        slider("间距", value: $settings.watermark.spacing, in: 0.5...5, format: { String(format: "%.1f", $0) })
                        ColorPaletteRow(colorHex: $settings.watermark.colorHex)
                    }
                } header: {
                    Text("浮水印")
                } footer: {
                    Text("给证件照注明用途，防止被挪作他用。对所有图片生效。")
                }

                Section {
                    NavigationLink("查看原图 EXIF") { MetadataView(metadata: item.metadata) }
                } footer: {
                    Text("导出的图片只保留像素，不含位置、设备、拍摄时间等信息。")
                }

                // 分享扩展里的图片不是从相册选的，没有原图可删
                if item.assetIdentifier != nil {
                    Section {
                        Toggle("保存后删除原图", isOn: $settings.deleteOriginal)
                    } footer: {
                        Text("保存打码后的图片后，把相册里的原图移到「最近删除」，系统会先请你确认。需要允许「完全访问」照片；受限访问时无法删除。")
                    }
                }
            }
            .navigationTitle("导出选项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func slider(_ title: String, value: Binding<CGFloat>, in range: ClosedRange<CGFloat>,
                        format: @escaping (CGFloat) -> String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }
}

/// 原图元数据：让用户看到"如果不打码直接发出去，会泄露哪些信息"
struct MetadataView: View {
    let metadata: [String: Any]

    private static let groups: [(key: String, title: String)] = [
        ("{GPS}", "位置"), ("{TIFF}", "设备"), ("{Exif}", "拍摄"), ("{ExifAux}", "镜头"), ("{MakerApple}", "Apple 附加信息"),
    ]
    private static let names: [String: String] = [
        "Latitude": "纬度", "LatitudeRef": "纬度方向", "Longitude": "经度", "LongitudeRef": "经度方向", "Altitude": "海拔",
        "Speed": "速度", "ImgDirection": "朝向", "DateStamp": "GPS 日期", "TimeStamp": "GPS 时间",
        "Make": "厂商", "Model": "机型", "Software": "系统版本", "DateTime": "修改时间", "HostComputer": "设备",
        "DateTimeOriginal": "拍摄时间", "DateTimeDigitized": "数字化时间", "OffsetTimeOriginal": "时区",
        "LensModel": "镜头", "LensMake": "镜头厂商", "UserComment": "备注", "PixelXDimension": "宽", "PixelYDimension": "高",
        "ISOSpeedRatings": "ISO", "ExposureTime": "快门", "FNumber": "光圈", "FocalLength": "焦距",
    ]

    var body: some View {
        List {
            Section {
                Label(sensitiveGroups.isEmpty ? "原图不含位置或设备信息" : "导出的文件不包含以下任何信息",
                      systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
            }
            ForEach(Self.groups, id: \.key) { group in
                if let dict = metadata[group.key] as? [String: Any], !dict.isEmpty {
                    Section(group.title) {
                        ForEach(dict.keys.sorted(), id: \.self) { key in
                            LabeledContent(Self.names[key] ?? key, value: Self.describe(dict[key]))
                        }
                    }
                }
            }
            Section("基本信息") {
                ForEach(topLevelKeys, id: \.self) { key in
                    LabeledContent(key, value: Self.describe(metadata[key]))
                }
            }
        }
        .navigationTitle("原图 EXIF")
    }

    /// 位置和设备信息才算敏感
    private var sensitiveGroups: [String] {
        ["{GPS}", "{TIFF}"].filter { (metadata[$0] as? [String: Any])?.isEmpty == false }
    }

    private var topLevelKeys: [String] {
        metadata.keys.filter { metadata[$0] as? [String: Any] == nil }.sorted()
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let v as [Any]: v.map { describe($0) }.joined(separator: ", ")
        case let v as Double: v == v.rounded() ? String(Int(v)) : String(format: "%.6g", v)
        case let v?: String(describing: v)
        case nil: "—"
        }
    }
}
#endif
