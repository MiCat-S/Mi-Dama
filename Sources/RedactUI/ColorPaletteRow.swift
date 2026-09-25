// 颜色选择行：预设色 + 系统取色器（打码色块和水印共用）
#if canImport(UIKit)
import SwiftUI

struct ColorPaletteRow: View {
    @Binding var colorHex: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Preferences.palette, id: \.hex) { c in
                    Circle()
                        .fill(Color(hex: c.hex))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 1))
                        .overlay(Circle().stroke(.tint, lineWidth: 3).padding(-4).opacity(colorHex == c.hex ? 1 : 0))
                        .onTapGesture { colorHex = c.hex }
                        .accessibilityLabel(c.name)
                        .accessibilityAddTraits(colorHex == c.hex ? .isSelected : [])
                }
                ColorPicker("自定义", selection: Binding(get: { Color(hex: colorHex) }, set: { colorHex = $0.hexString }),
                            supportsOpacity: false)
                    .labelsHidden()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }
}
#endif
