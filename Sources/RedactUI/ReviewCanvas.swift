// 审核页的画布：图片 + 识别框（点一下开关、长按单独设置）+ 手动画框
#if canImport(UIKit)
import RedactKit
import SwiftUI

struct ReviewCanvas: View {
    @Bindable var item: RedactItem
    /// true = 显示打码效果预览，识别框隐藏
    let showPreview: Bool
    let preview: UIImage?
    /// 手动画框模式
    let drawing: Bool
    /// 每次改动勾选 / 加框时调用（触感反馈）
    let onEdit: () -> Void

    @State private var dragRect: CGRect?

    var body: some View {
        if let display = item.displayImage {
            Image(uiImage: showPreview ? (preview ?? display) : display)
                .resizable()
                .scaledToFit()
                .overlay { overlay }
        } else {
            ProgressView("正在读取图片…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var overlay: some View {
        GeometryReader { geo in
            let scale = geo.size.width / item.size.width
            ZStack(alignment: .topLeading) {
                // 动效只用透明度 / 颜色：识别完成时框淡入，切到打码预览时淡出；
                // 不涉及位移，开启「减弱动态效果」时也合适
                ForEach(item.findings) { finding in
                    FindingBoxView(finding: finding, scale: scale)
                        .onTapGesture { toggle(finding.id) }
                        .contextMenu { FindingMenu(finding: finding, item: item, onEdit: onEdit) }
                        .transition(.opacity)
                }
                .opacity(showPreview ? 0 : 1)
                .allowsHitTesting(!showPreview)
                .animation(.easeOut(duration: 0.25), value: item.findings.count)
                .animation(.easeInOut(duration: 0.2), value: showPreview)
                if let dragRect {
                    Rectangle().stroke(.yellow, lineWidth: 2)
                        .frame(width: dragRect.width, height: dragRect.height)
                        .offset(x: dragRect.minX, y: dragRect.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(drawing ? drawGesture(scale: scale) : nil)
        }
    }

    private func toggle(_ id: UUID) {
        item.updateFinding(id) { $0.isEnabled.toggle() }
        onEdit()
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
                    onEdit()
                }
                dragRect = nil
            }
    }
}

/// 一个识别框：勾选时半透明填充 + 实线，未勾选时只有虚线；单独指定了效果时右上角标出效果名
struct FindingBoxView: View {
    let finding: Finding
    let scale: CGFloat

    var body: some View {
        let r = finding.rect
        let tint = finding.kind.tint
        Rectangle()
            .fill(finding.isEnabled ? tint.opacity(0.25) : .clear)
            .overlay(Rectangle().stroke(tint, style: StrokeStyle(lineWidth: 1.5, dash: finding.isEnabled ? [] : [4, 3])))
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
            // 点一下立即有反馈：填充在约 0.12 秒内淡入 / 淡出
            .animation(.easeOut(duration: 0.12), value: finding.isEnabled)
            .frame(width: max(8, r.width * scale), height: max(8, r.height * scale))
            // 未勾选时填充是透明的，SwiftUI 不会命中透明区域，必须显式指定点击范围
            .contentShape(Rectangle())
            .offset(x: r.minX * scale, y: r.minY * scale)
            .accessibilityLabel("\(finding.kind.label)\(finding.isEnabled ? "，已勾选" : "，未勾选")")
    }
}

/// 长按一个框：单独开关、单独换效果、删除手动框
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
                item.findings.removeAll { $0.id == finding.id }
                onEdit()
            }
        }
    }

    private var styleBinding: Binding<MaskStyle?> {
        Binding(get: { finding.style },
                set: { v in item.updateFinding(finding.id) { $0.style = v; $0.isEnabled = true } })
    }
}

extension FindingKind {
    /// 审核页里各类别的颜色：聊天布局蓝、人脸橙、条码紫、手动黄、文字红
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
