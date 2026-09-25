// 编辑画布：直接显示打码后的效果（所见即所得）
//  · 点一下打码区域 → 取消这一处（露出原图，留一圈虚线方便再点回来）；再点 → 恢复
//  · 长按 → 单独设置这一处的效果 / 删除手动框
//  · 文字工具：点一下文字行，盖住整行；马克笔工具：拖出一个框
#if canImport(UIKit)
import RedactKit
import SwiftUI

/// 当前的编辑工具；nil = 普通模式（点区域开关）
public enum EditTool: String, Identifiable {
    case text, marker
    public var id: String { rawValue }
}

struct ReviewCanvas: View {
    let item: RedactItem
    /// 打码后的渲染结果；还没渲染好时显示原图
    let rendered: UIImage?
    let tool: EditTool?
    /// 每次编辑后调用（触感反馈）
    let onEdit: () -> Void

    @State private var dragRect: CGRect?

    var body: some View {
        if let display = item.displayImage {
            Image(uiImage: rendered ?? display)
                .resizable()
                .scaledToFit()
                .overlay { overlay }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        } else {
            ProgressView("正在读取图片…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var overlay: some View {
        GeometryReader { geo in
            let scale = geo.size.width / item.size.width
            ZStack(alignment: .topLeading) {
                // 文字工具下不响应区域点击，让点击落到文字行上
                ForEach(item.findings) { finding in
                    FindingBoxView(finding: finding, scale: scale)
                        .onTapGesture { toggle(finding.id) }
                        .contextMenu { FindingMenu(finding: finding, item: item, onEdit: onEdit) }
                        .transition(.opacity)
                }
                .allowsHitTesting(tool == nil)
                .animation(.easeOut(duration: 0.25), value: item.findings.count)
                if let dragRect {
                    Rectangle().stroke(.yellow, lineWidth: 2)
                        .frame(width: dragRect.width, height: dragRect.height)
                        .offset(x: dragRect.minX, y: dragRect.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(tool == .marker ? markerGesture(scale: scale) : nil)
            .simultaneousGesture(tool == .text ? textTapGesture(scale: scale) : nil)
        }
    }

    private func toggle(_ id: UUID) {
        item.updateFinding(id) { $0.isEnabled.toggle() }
        onEdit()
    }

    private func textTapGesture(scale: CGFloat) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            let p = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
            let before = item.findings
            item.toggleTextLine(at: p)
            if item.findings != before { onEdit() }
        }
    }

    private func markerGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                dragRect = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                  width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
            }
            .onEnded { _ in
                if let r = dragRect, r.width > 6, r.height > 6 {
                    let imageRect = CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
                    item.addFinding(Finding(kind: .manual, rect: imageRect, confidence: 1))
                    onEdit()
                }
                dragRect = nil
            }
    }
}

/// 一个区域的点击范围。打码中的区域不画任何东西（效果已经在图上）；
/// 没在打码的区域画一圈虚线，提示"这里识别到了，点一下可以打码"
struct FindingBoxView: View {
    let finding: Finding
    let scale: CGFloat

    var body: some View {
        let r = finding.rect
        let tint = finding.kind.tint
        Rectangle()
            .fill(.clear)
            .overlay {
                if !finding.isEnabled {
                    Rectangle().stroke(tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .background(tint.opacity(0.08))
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let style = finding.style, finding.isEnabled {
                    // 角标贴在框的上沿外侧：字号变大时自动往上长，不会压住框
                    Text(style.label).font(.caption2.weight(.semibold)).dynamicTypeSize(...DynamicTypeSize.large)
                        .padding(.horizontal, 3)
                        .background(tint, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
                        .fixedSize()
                        .alignmentGuide(.top) { $0[.bottom] }
                }
            }
            .animation(.easeOut(duration: 0.12), value: finding.isEnabled)
            .frame(width: max(8, r.width * scale), height: max(8, r.height * scale))
            // 填充是透明的，SwiftUI 不会命中透明区域，必须显式指定点击范围
            .contentShape(Rectangle())
            .offset(x: r.minX * scale, y: r.minY * scale)
            .accessibilityLabel("\(finding.kind.label)，\(finding.isEnabled ? "已打码" : "未打码")")
            .accessibilityHint("点按切换是否打码")
    }
}

/// 长按一个区域：单独开关、单独换效果、删除手动框
struct FindingMenu: View {
    let finding: Finding
    let item: RedactItem
    let onEdit: () -> Void

    var body: some View {
        Button(finding.isEnabled ? "这一处不打码" : "这一处打码", systemImage: finding.isEnabled ? "eye" : "eye.slash") {
            item.updateFinding(finding.id) { $0.isEnabled.toggle() }
            onEdit()
        }
        Picker("这一处的效果", selection: styleBinding) {
            Text("跟随全局（\(item.styleOverride?.label ?? "自动")）").tag(MaskStyle?.none)
            ForEach(MaskStyle.allCases, id: \.self) { Text($0.label).tag(MaskStyle?.some($0)) }
        }
        .pickerStyle(.menu)
        if finding.kind == .manual {
            Button("删除这个框", systemImage: "trash", role: .destructive) {
                item.removeFinding(finding.id)
                onEdit()
            }
        }
    }

    private var styleBinding: Binding<MaskStyle?> {
        Binding(get: { finding.style },
                set: { v in item.updateFinding(finding.id) { $0.style = v; $0.isEnabled = true }; onEdit() })
    }
}

extension FindingKind {
    /// 各类别的颜色：聊天布局蓝、人脸橙、条码紫、手动黄、文字红
    var tint: Color {
        switch self {
        case .chatAvatar, .chatNickname, .chatTitle, .chatSystemMessage: .blue
        case .face: .orange
        case .qrCode, .barcode: .purple
        case .manual: .yellow
        default: .red
        }
    }
}
#endif
