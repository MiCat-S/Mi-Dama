// 编辑页底部工具栏（仿 DAMA）：
//  [自动打码开关]   [当前效果 ⌃ | 文字 | 马克笔]   [颜色]
//  · 自动打码：点一下全部开 / 关；长按按类别开关
//  · 效果：点开向上弹出的菜单，每项带真实效果小样
//  · 颜色：色块、杂讯色块用的颜色
#if canImport(UIKit)
import RedactKit
import SwiftUI

struct ReviewBottomBar: View {
    let item: RedactItem
    @Binding var tool: EditTool?
    @Binding var colorHex: String
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            AutoRedactButton(item: item, onEdit: onEdit)
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                EffectMenu(item: item, colorHex: colorHex, onEdit: onEdit)
                ToolButton(tool: .text, systemImage: "textformat", label: "文字", selection: $tool)
                ToolButton(tool: .marker, systemImage: "highlighter", label: "马克笔", selection: $tool)
            }
            .padding(.horizontal, 8)
            .frame(height: 56)
            .glassCapsule()
            Spacer(minLength: 12)
            FillColorButton(colorHex: $colorHex, isEnabled: item.styleOverride?.usesColor ?? false)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// 左侧圆形按钮：自动打码总开关
struct AutoRedactButton: View {
    let item: RedactItem
    let onEdit: () -> Void

    var body: some View {
        let on = item.isAutoRedactionOn
        Menu {
            // 长按：按类别开关（原来的类别标签搬到这里）
            ForEach(item.kindCounts.filter { $0.kind != .manual }, id: \.kind) { entry in
                Toggle("\(entry.kind.label)（\(entry.count)）", isOn: Binding(
                    get: { entry.enabled },
                    set: { item.setFindings(of: entry.kind, enabled: $0); onEdit() }
                ))
            }
        } label: {
            Image(systemName: on ? "wand.and.sparkles" : "wand.and.sparkles.inverse")
                .font(.title3)
                .foregroundStyle(on ? .white : .secondary)
                .frame(width: 56, height: 56)
                .glassCircle(tint: on ? .green : nil)
        } primaryAction: {
            item.setAutoRedaction(!on)
            onEdit()
        }
        .disabled(item.isDetecting)
        .accessibilityLabel(on ? "自动打码：开" : "自动打码：关")
        .accessibilityHint("点按全部开关，长按按类别开关")
    }
}

/// 当前效果 + 向上弹出的效果菜单
struct EffectMenu: View {
    let item: RedactItem
    let colorHex: String
    let onEdit: () -> Void

    var body: some View {
        Menu {
            Picker("打码效果", selection: Binding(get: { item.styleOverride },
                                               set: { item.setStyle($0); onEdit() })) {
                row(nil, "自动")
                ForEach(MaskStyle.allCases, id: \.self) { row($0, $0.label) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(uiImage: EffectPreview.swatch(item.styleOverride, colorHex: colorHex, side: 28))
                    .resizable()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .frame(height: 44)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("打码效果：\(item.styleOverride?.label ?? "自动")")
    }

    private func row(_ style: MaskStyle?, _ title: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(uiImage: EffectPreview.swatch(style, colorHex: colorHex, side: 28).withRenderingMode(.alwaysOriginal))
        }
        .tag(style)
    }
}

/// 工具按钮：再点一次取消（回到"点区域开关"的普通模式）
struct ToolButton: View {
    let tool: EditTool
    let systemImage: String
    let label: String
    @Binding var selection: EditTool?

    var body: some View {
        let selected = selection == tool
        Button {
            selection = selected ? nil : tool
        } label: {
            // textformat 在中文环境会本地化成"格式"字样，固定用英文字形显示 "Aa"
            Image(systemName: systemImage)
                .environment(\.locale, Locale(identifier: "en"))
                .font(.title3)
                .frame(width: 44, height: 44)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 右侧圆形按钮：色块颜色（系统取色器的彩色圆环）
struct FillColorButton: View {
    @Binding var colorHex: String
    let isEnabled: Bool

    var body: some View {
        ColorPicker("色块颜色", selection: Binding(get: { Color(hex: colorHex) }, set: { colorHex = $0.hexString }),
                    supportsOpacity: false)
            .labelsHidden()
            .frame(width: 56, height: 56)
            .glassCircle()
            .opacity(isEnabled ? 1 : 0.4)
            .disabled(!isEnabled)
            .accessibilityHint(isEnabled ? "" : "选择色块或杂讯色块效果后可用")
    }
}
#endif
