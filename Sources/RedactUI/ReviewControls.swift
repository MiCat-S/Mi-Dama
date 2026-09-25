// 审核页底部浮动面板：类别开关 + 识别框 / 打码效果切换 + 效果按钮 + 手动框选
#if canImport(UIKit)
import RedactKit
import SwiftUI

struct ReviewControls: View {
    @Bindable var item: RedactItem
    @Binding var showPreview: Bool
    @Binding var drawing: Bool
    let onShowEffects: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            CategoryChips(item: item, onEdit: onEdit)
            HStack {
                Picker("显示", selection: $showPreview) {
                    Text("识别框").tag(false)
                    Text("打码效果").tag(true)
                }
                .pickerStyle(.segmented)
                EffectButton(style: item.styleOverride, colorHex: item.fillColorHex, action: onShowEffects)
                Toggle(isOn: $drawing) { Image(systemName: "rectangle.dashed.badge.record") }
                    .toggleStyle(.button)
                    .accessibilityLabel("手动框选")
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .floatingPanel(.bottom)
    }
}

/// 每个类别一个标签，点一下整组开 / 关；面板本身已是玻璃，标签用实心浅色填充
struct CategoryChips: View {
    let item: RedactItem
    let onEdit: () -> Void

    var body: some View {
        let counts = item.kindCounts
        if !counts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(counts, id: \.kind) { entry in
                        Button {
                            item.setFindings(of: entry.kind, enabled: !entry.enabled)
                            onEdit()
                        } label: {
                            Text("\(entry.kind.label) \(entry.count)")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(entry.enabled ? entry.kind.tint.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
                                .foregroundStyle(entry.enabled ? entry.kind.tint : .secondary)
                        }
                        .accessibilityAddTraits(entry.enabled ? .isSelected : [])
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// 当前打码效果：缩略图 + 名称，点开效果面板
struct EffectButton: View {
    let style: MaskStyle?
    let colorHex: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(uiImage: EffectPreview.image(style, colorHex: colorHex))
                    .resizable().frame(width: 32, height: 12).clipShape(RoundedRectangle(cornerRadius: 3))
                Text(style?.label ?? "自动").font(.footnote.weight(.medium)).lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("打码效果：\(style?.label ?? "自动")")
    }
}
#endif
