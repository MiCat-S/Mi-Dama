// 审核页：进入即开始识别。看识别框、点框取消 / 恢复、长按框单独换效果、按类别整组开关、手动补框、选打码效果，
// 右上角「导出」在一个面板里选格式 / 大小 / 水印 / 是否删原图，再保存或分享
#if canImport(UIKit)
import RedactKit
import SwiftUI

public struct ReviewView: View {
    @Bindable var item: RedactItem
    @State private var showPreview = false
    @State private var drawing = false
    @State private var preview: UIImage?
    @State private var report: SaveReport?
    /// 同一时间只会有一个弹窗，用一个枚举驱动
    @State private var sheet: ReviewSheet?
    /// 每次点框 / 类别 / 画框都加一，驱动轻触反馈
    @State private var selectionTicks = 0
    /// 底部浮动面板的高度，交给缩放视图留出滚动空间
    @State private var controlsHeight: CGFloat = 0
    private let settings = ExportSettings.shared
    /// 保存完成后的回调（分享扩展用它结束扩展）；为 nil 时弹出结果提示
    private let onSaved: ((SaveReport) -> Void)?

    enum ReviewSheet: String, Identifiable {
        case effects, export
        var id: String { rawValue }
    }

    public init(item: RedactItem, onSaved: ((SaveReport) -> Void)? = nil) {
        self.item = item
        self.onSaved = onSaved
    }

    public var body: some View {
        ZoomableView(aspect: item.size.height / max(1, item.size.width), isScrollEnabled: !drawing,
                     bottomInset: controlsHeight) {
            ReviewCanvas(item: item, showPreview: showPreview, preview: preview, drawing: drawing) { selectionTicks += 1 }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            if item.isDetecting && item.displayImage != nil {
                ProgressView("识别中…")
                    .padding()
                    .glassBadge()
            }
        }
        // 控件浮在图片上方，图片从下面滚过
        .overlay(alignment: .bottom) {
            ReviewControls(item: item, showPreview: $showPreview, drawing: $drawing,
                           onShowEffects: { sheet = .effects }, onEdit: { selectionTicks += 1 })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导出") { sheet = .export }
                    .primaryActionStyle()
                    .disabled(item.isDetecting)
            }
        }
        .task { await item.loadDisplayImage() }
        .task { await item.detectIfNeeded() }
        .onDisappear { item.releaseDisplayImage() }
        .task(id: renderKey) {
            guard showPreview else { return }
            preview = await item.renderPreview()
        }
        .reportAlert($report)
        .sensoryFeedback(.selection, trigger: selectionTicks)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .effects:
                EffectSheet(style: $item.styleOverride, colorHex: $item.fillColorHex)
            case .export:
                ExportSheet(items: [item]) { result in
                    if let onSaved { onSaved(result) } else { report = result }
                }
            }
        }
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
        case .pending, .detecting: "识别中…"
        case .failed: "识别失败"
        default: item.findings.isEmpty ? "未发现敏感信息" : "已勾选 \(item.enabledCount) / \(item.findings.count)"
        }
    }

    private var watermarkKey: String { String(describing: settings.activeWatermark) }
}
#endif
