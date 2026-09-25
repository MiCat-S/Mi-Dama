// 审核页：看识别框、点框取消 / 恢复、长按框单独换效果、按类别整组开关、手动补框、选打码效果、导出选项、保存或分享
#if canImport(UIKit)
import RedactKit
import SwiftUI

public struct ReviewView: View {
    @Bindable var item: RedactItem
    @State private var showPreview = false
    @State private var drawing = false
    @State private var dragRect: CGRect?
    @State private var preview: UIImage?
    @State private var message: String?
    @State private var showEffects = false
    @State private var showExportOptions = false
    private let settings = ExportSettings.shared
    /// 保存成功后的回调（分享扩展用它结束扩展）；为 nil 时弹出提示
    private let onSaved: (() -> Void)?

    public init(item: RedactItem, onSaved: (() -> Void)? = nil) {
        self.item = item
        self.onSaved = onSaved
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZoomableView(aspect: item.size.height / max(1, item.size.width), isScrollEnabled: !drawing) {
                canvas
            }
            .overlay {
                if item.phase == .detecting {
                    ProgressView("识别中…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            controls
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showExportOptions = true } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("导出选项")
                ShareLink(item: item.export, preview: SharePreview("打码后的图片", image: Image(uiImage: preview ?? item.displayImage)))
                Button("保存") { Task { await save() } }
            }
        }
        .task(id: renderKey) {
            guard showPreview else { return }
            preview = await item.renderPreview()
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") {}
        }
        .sheet(isPresented: $showEffects) {
            EffectSheet(style: $item.styleOverride, colorHex: $item.fillColorHex)
        }
        .sheet(isPresented: $showExportOptions) {
            ExportOptionsSheet(settings: settings, item: item)
        }
        // 水印变了也切到效果预览，才看得到
        .onChange(of: watermarkKey) { showPreview = true }
        // 换了效果就切到效果预览，并记住作为下次的默认
        .onChange(of: item.styleOverride) { _, new in
            Preferences.style = new
            showPreview = true
        }
        .onChange(of: item.fillColorHex) { _, new in
            Preferences.colorHex = new
            showPreview = true
        }
    }

    /// 勾选或样式变化时重新渲染预览
    private var renderKey: String {
        "\(showPreview)-\(item.styleOverride?.rawValue ?? "auto")-\(item.fillColorHex)-\(watermarkKey)-"
            + item.findings.map { "\($0.id)\($0.isEnabled)\($0.style?.rawValue ?? "")" }.joined()
    }

    private var title: String {
        switch item.phase {
        case .detecting: "识别中…"
        case .cancelled: "未识别"
        default: item.findings.isEmpty ? "未发现敏感信息" : "已勾选 \(item.enabledCount) / \(item.findings.count)"
        }
    }

    private var watermarkKey: String { String(describing: settings.activeWatermark) }

    // MARK: - 图片与识别框

    private var canvas: some View {
        Image(uiImage: showPreview ? (preview ?? item.displayImage) : item.displayImage)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geo in
                    let scale = geo.size.width / item.size.width
                    ZStack(alignment: .topLeading) {
                        if !showPreview {
                            ForEach(item.findings) { f in
                                box(f, scale: scale)
                                    .onTapGesture { update(f.id) { $0.isEnabled.toggle() } }
                                    .contextMenu { boxMenu(f) }
                            }
                        }
                        if let r = dragRect {
                            Rectangle().stroke(.yellow, lineWidth: 2)
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .gesture(drawing ? drawGesture(scale: scale) : nil)
                }
            }
    }

    private func box(_ f: Finding, scale: CGFloat) -> some View {
        let r = f.rect
        return Rectangle()
            .fill(f.isEnabled ? color(f.kind).opacity(0.25) : .clear)
            .overlay(Rectangle().stroke(color(f.kind), style: StrokeStyle(lineWidth: 1.5, dash: f.isEnabled ? [] : [4, 3])))
            // 单独指定了效果的框，右上角标出效果名
            .overlay(alignment: .topTrailing) {
                if let s = f.style, f.isEnabled {
                    Text(s.label).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 3)
                        .background(color(f.kind), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
                        .fixedSize().offset(y: -12)
                }
            }
            .frame(width: max(8, r.width * scale), height: max(8, r.height * scale))
            // 未勾选时填充是透明的，SwiftUI 不会命中透明区域，必须显式指定点击范围
            .contentShape(Rectangle())
            .offset(x: r.minX * scale, y: r.minY * scale)
            .accessibilityLabel("\(f.kind.label)\(f.isEnabled ? "，已勾选" : "，未勾选")")
    }

    /// 长按一个框：单独开关、单独换效果、删除手动框
    @ViewBuilder
    private func boxMenu(_ f: Finding) -> some View {
        Button(f.isEnabled ? "这一处不打码" : "这一处打码", systemImage: f.isEnabled ? "eye" : "eye.slash") {
            update(f.id) { $0.isEnabled.toggle() }
        }
        Picker("这一处的效果", selection: Binding(get: { f.style }, set: { v in update(f.id) { $0.style = v; $0.isEnabled = true } })) {
            Text("跟随全局（\(item.styleOverride?.label ?? "自动")）").tag(MaskStyle?.none)
            ForEach(MaskStyle.allCases, id: \.self) { Text($0.label).tag(MaskStyle?.some($0)) }
        }
        .pickerStyle(.menu)
        if f.kind == .manual {
            Button("删除这个框", systemImage: "trash", role: .destructive) {
                item.findings.removeAll { $0.id == f.id }
            }
        }
    }

    /// 按 id 修改（不直接用 ForEach 的绑定，避免删除时越界）
    private func update(_ id: UUID, _ change: (inout Finding) -> Void) {
        if let i = item.findings.firstIndex(where: { $0.id == id }) { change(&item.findings[i]) }
    }

    private func drawGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                dragRect = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                  width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
            }
            .onEnded { _ in
                if let r = dragRect, r.width > 6, r.height > 6 {
                    let imageRect = CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
                    item.findings.append(Finding(kind: .manual, rect: imageRect, confidence: 1))
                }
                dragRect = nil
            }
    }

    private func color(_ kind: FindingKind) -> Color {
        switch kind {
        case .chatAvatar, .chatNickname, .chatTitle, .chatSystemMessage: .blue
        case .face: .orange
        case .qrCode, .barcode: .purple
        case .manual: .yellow
        default: .red
        }
    }

    // MARK: - 底部控制

    private var kinds: [(FindingKind, Int, Bool)] {
        Dictionary(grouping: item.findings, by: \.kind)
            .map { ($0.key, $0.value.count, $0.value.contains(where: \.isEnabled)) }
            // 数量相同时按类别固定顺序，避免点选后标签跳来跳去
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if !kinds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(kinds, id: \.0) { kind, count, on in
                            Button { setAll(kind, !on) } label: {
                                Text("\(kind.label) \(count)")
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(on ? color(kind).opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
                                    .foregroundStyle(on ? color(kind) : .secondary)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            HStack {
                Picker("显示", selection: $showPreview) {
                    Text("识别框").tag(false)
                    Text("打码效果").tag(true)
                }
                .pickerStyle(.segmented)
                Button { showEffects = true } label: {
                    HStack(spacing: 6) {
                        Image(uiImage: EffectPreview.image(item.styleOverride, colorHex: item.fillColorHex))
                            .resizable().frame(width: 32, height: 12).clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(item.styleOverride?.label ?? "自动").font(.footnote.weight(.medium)).lineLimit(1)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("打码效果：\(item.styleOverride?.label ?? "自动")")
                Toggle(isOn: $drawing) { Image(systemName: "rectangle.dashed.badge.record") }
                    .toggleStyle(.button)
                    .accessibilityLabel("手动框选")
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func setAll(_ kind: FindingKind, _ enabled: Bool) {
        for i in item.findings.indices where item.findings[i].kind == kind {
            item.findings[i].isEnabled = enabled
        }
    }

    private func save() async {
        do {
            let export = item.export
            let data = try await Task.detached { try export.data() }.value
            try await PhotoSaver.save(data)
            item.phase = .saved
        } catch {
            message = error.localizedDescription
            return
        }
        if let onSaved {
            onSaved()
            return
        }
        // 只有保存成功后才删原图
        var deletion: Result<PhotoSaver.DeleteOutcome, Error>?
        if settings.deleteOriginal {
            if let id = item.assetIdentifier {
                do { deletion = .success(try await PhotoSaver.deleteOriginals([id])) } catch { deletion = .failure(error) }
            } else {
                message = "已保存到相册（这张图不是从相册选的，无法删除原图）"
                return
            }
        }
        message = PhotoSaver.summary(saved: 1, deletion: deletion)
    }
}
#endif
