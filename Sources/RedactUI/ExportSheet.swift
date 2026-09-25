// 导出：一个面板里选好格式、大小、浮水印、是否删除原图，然后直接保存或分享。
// 每次导出都会看到这些选项；上次的选择会被记住作为默认值
#if canImport(UIKit)
import RedactKit
import SwiftUI

public struct ExportSheet: View {
    let items: [RedactItem]
    /// 保存由面板自己完成并关闭；结果交给弹出方显示（分享扩展据此直接结束扩展）
    let onSaved: (SaveReport) -> Void
    @Bindable private var settings = ExportSettings.shared
    @State private var preview: UIImage?
    @State private var saved: Int?
    @Environment(\.dismiss) private var dismiss

    public init(items: [RedactItem], onSaved: @escaping (SaveReport) -> Void) {
        self.items = items
        self.onSaved = onSaved
    }

    private var first: RedactItem? { items.first }
    private var canDeleteOriginals: Bool { items.contains { $0.assetIdentifier != nil } }

    public var body: some View {
        NavigationStack {
            Form {
                previewSection

                Section {
                    Picker("格式", selection: $settings.format) {
                        ForEach(ExportSettings.FormatChoice.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("大小", selection: $settings.size) {
                        ForEach(ExportSettings.SizeChoice.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    if let first {
                        let out = settings.size.exportSize.apply(to: first.source).extent.size
                        let ext = settings.exportFormat(isScreenshot: first.isScreenshot).fileExtension.uppercased()
                        Text(items.count == 1
                             ? "导出为 \(Int(out.width)) × \(Int(out.height))，\(ext)。缩放在打码之后进行，不会削弱打码。"
                             : "共 \(items.count) 张。缩放在打码之后进行，不会削弱打码。")
                    }
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
                    Text("给证件照注明用途，防止被挪作他用。")
                }

                // 从相册以外（分享扩展、系统选择器受限时）打开的图没有原图可删
                if canDeleteOriginals {
                    Section {
                        Toggle("保存后删除原图", isOn: $settings.deleteOriginal)
                    } footer: {
                        Text("保存后把相册里的原图移到「最近删除」，系统会先请你确认。需要允许「完全访问」照片。")
                    }
                }

                if items.count == 1, let first {
                    Section {
                        NavigationLink("查看原图 EXIF") { MetadataView(metadata: first.metadata) }
                    } footer: {
                        Text("导出的图片只保留像素，不含位置、设备、拍摄时间等信息。")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle(items.count == 1 ? "导出" : "导出 \(items.count) 张")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .interactiveDismissDisabled(saved != nil)
        }
        .presentationDetents([.large])
    }

    /// 缩略预览：选项一改就重新渲染，水印、格式变化一眼可见
    private var previewSection: some View {
        Section {
            HStack {
                Spacer()
                Group {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
        .task(id: previewKey) {
            guard let first else { return }
            try? await Task.sleep(for: .milliseconds(150))   // 拖动滑杆时不要每一帧都重渲染
            guard !Task.isCancelled else { return }
            preview = await first.renderPreview()
        }
    }

    private var previewKey: String {
        "\(String(describing: settings.activeWatermark))-\(settings.size)-\(settings.format)"
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let saved {
                ProgressView(value: Double(saved), total: Double(max(1, items.count))) {
                    Text("保存中 \(saved)/\(items.count)").font(.footnote).monospacedDigit()
                }
            } else {
                Button { Task { await save() } } label: {
                    Label(items.count == 1 ? "保存到相册" : "全部保存到相册（\(items.count) 张）", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                ShareLink(items: items.map(\.export)) { exports in
                    SharePreview(items.count == 1 ? "打码后的图片" : "\(items.count) 张打码后的图片",
                                 image: Image(uiImage: preview ?? UIImage()))
                } label: {
                    Label("分享…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.bar)
    }

    private func save() async {
        saved = 0
        let report = await PhotoSaver.saveAll(items, deletingOriginals: settings.deleteOriginal && canDeleteOriginals) { n in
            saved = n
        }
        saved = nil
        dismiss()
        onSaved(report)
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
