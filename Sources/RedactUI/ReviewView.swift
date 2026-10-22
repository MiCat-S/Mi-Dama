// 编辑页（仿 DAMA）：进入即识别并直接显示打码结果
//  顶栏：返回 · 撤销 / 重做 · 帮助 · 分享（导出选项）· ✓ 按当前设置直接保存
//  画布：点阵画板上的图片卡片，双指缩放；底栏见 ReviewBottomBar
#if canImport(UIKit)
import RedactKit
import SwiftUI

public struct ReviewView: View {
    let item: RedactItem
    /// 保存完成后的回调（批量模式跳到下一张、分享扩展结束扩展）；为 nil 时成功后返回上一页
    private let onSaved: ((SaveReport) -> Void)?

    @State private var rendered: UIImage?
    @State private var tool: EditTool?
    @State private var sheet: ReviewSheet?
    @State private var toast: EditorToast?
    @State private var report: SaveReport?
    @State private var saving = false
    /// 每次编辑加一，驱动轻触反馈
    @State private var editTicks = 0
    /// 底部工具栏顶边到画布底边的距离（含 Home 指示条区域），交给缩放视图留出空间
    @State private var barTop: CGFloat = 0
    @State private var canvasBottom: CGFloat = 0
    @State private var colorHex: String
    private let settings = ExportSettings.shared
    @Environment(\.dismiss) private var dismiss

    enum ReviewSheet: String, Identifiable {
        case export, help
        var id: String { rawValue }
    }

    public init(item: RedactItem, onSaved: ((SaveReport) -> Void)? = nil) {
        self.item = item
        self.onSaved = onSaved
        _colorHex = State(initialValue: item.fillColorHex)
    }

    public var body: some View {
        ZoomableView(aspect: item.size.height / max(1, item.size.width), isScrollEnabled: tool != .marker,
                     bottomInset: max(0, canvasBottom - barTop)) {
            ReviewCanvas(item: item, rendered: rendered, tool: tool) { editTicks += 1 }
        }
        .background {
            // 背景铺满全屏（含 Home 指示条区域），用它量出屏幕底边
            DotGridBackground()
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { canvasBottom = $0 }
                .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            if item.isDetecting && item.displayImage != nil {
                ProgressView("识别中…").padding().glassBadge().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: item.isDetecting)
        .editorToast($toast)
        .overlay(alignment: .bottom) {
            ReviewBottomBar(item: item, tool: $tool, colorHex: $colorHex) { editTicks += 1 }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barTop = $0 }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ReviewToolbar(item: item, saving: saving, onHelp: { sheet = .help },
                                onShare: { sheet = .export }, onDone: { Task { await quickSave() } }))
        .task { await item.loadDisplayImage() }
        .task {
            await item.detectIfNeeded()
            announceDetection()
        }
        .onDisappear { item.releaseDisplayImage() }
        // 所见即所得：勾选、效果、颜色、水印变化后重新渲染；渲染期间保留上一张，不闪烁
        .task(id: renderKey) {
            guard !item.isDetecting, item.displayImage != nil else { return }
            let image = await item.renderPreview()
            // 渲染期间又改了：这张已经过时，交给最新那次，不能用它盖掉新结果
            guard !Task.isCancelled else { return }
            rendered = image
        }
        .onChange(of: colorHex) { _, new in
            item.fillColorHex = new
            Preferences.colorHex = new
        }
        .sensoryFeedback(.selection, trigger: editTicks)
        .reportAlert($report)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .export:
                ExportSheet(items: [item]) { handleSaved($0) }
            case .help:
                HelpSheet()
            }
        }
    }

    private var renderKey: String {
        "\(item.isDetecting)-\(item.displayImage != nil)-\(item.styleOverride?.rawValue ?? "auto")-\(item.fillColorHex)-"
            + "\(String(describing: settings.activeWatermark))-"
            + item.findings.map { "\($0.id)\($0.isEnabled)\($0.style?.rawValue ?? "")" }.joined()
    }

    private func announceDetection() {
        switch item.phase {
        case .ready:
            let count = item.findings.filter(\.isEnabled).count
            toast = count > 0
                ? EditorToast("找到 \(count) 处", systemImage: "checkmark.shield")
                : EditorToast("没有发现敏感信息，可用下方工具手动打码", systemImage: "info.circle")
        case .failed(let reason):
            toast = EditorToast("识别失败：\(reason)", systemImage: "exclamationmark.triangle")
        default:
            break
        }
    }

    /// ✓：按当前导出设置直接保存，不再弹选项
    private func quickSave() async {
        saving = true
        defer { saving = false }
        let deleting = settings.deleteOriginal && item.assetIdentifier != nil
        handleSaved(await PhotoSaver.saveAll([item], deletingOriginals: deleting))
    }

    private func handleSaved(_ result: SaveReport) {
        if let onSaved {
            onSaved(result)
        } else if result.outcome == .success {
            toast = EditorToast("已保存", systemImage: "checkmark.circle.fill")
            // 成功后稍等一下让用户看到提示，再回到相册
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                dismiss()
            }
        } else {
            report = result
        }
    }
}

/// 顶栏：返回（系统）· 撤销 / 重做 · 帮助 · 分享 · ✓
/// iOS 26 上各组是独立的玻璃胶囊，✓ 用绿色的突出玻璃
struct ReviewToolbar: ViewModifier {
    let item: RedactItem
    let saving: Bool
    let onHelp: () -> Void
    let onShare: () -> Void
    let onDone: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbar {
                ToolbarItemGroup(placement: .topBarLeading) { undoRedo }
                ToolbarItemGroup(placement: .topBarTrailing) { helpShare }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    doneButton.buttonStyle(.glassProminent).tint(.green)
                }
            }
        } else {
            content.toolbar {
                ToolbarItemGroup(placement: .topBarLeading) { undoRedo }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    helpShare
                    doneButton.buttonStyle(.borderedProminent).tint(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var undoRedo: some View {
        Button("撤销", systemImage: "arrow.uturn.backward") { item.undo() }
            .disabled(!item.canUndo)
        Button("重做", systemImage: "arrow.uturn.forward") { item.redo() }
            .disabled(!item.canRedo)
    }

    @ViewBuilder
    private var helpShare: some View {
        Button("帮助", systemImage: "questionmark.circle", action: onHelp)
        Button("导出选项", systemImage: "square.and.arrow.up", action: onShare)
            .disabled(item.isDetecting)
    }

    private var doneButton: some View {
        Button(action: onDone) {
            if saving {
                ProgressView()
            } else {
                Image(systemName: "checkmark").fontWeight(.semibold)
            }
        }
        .disabled(item.isDetecting || saving)
        .accessibilityLabel("保存到相册")
    }
}
#endif
