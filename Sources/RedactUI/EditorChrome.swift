// 编辑器的外观部件：点阵画布背景、顶部提示条、圆形 / 胶囊玻璃按钮底
#if canImport(UIKit)
import SwiftUI

/// 点阵背景：图片像一张卡片放在画板上
struct DotGridBackground: View {
    var spacing: CGFloat = 18
    var dotSize: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: dotSize, height: dotSize))
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: .color(.primary.opacity(0.13)))
                    x += spacing
                }
                y += spacing
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityHidden(true)
    }
}

/// 短暂的提示（"找到 11 处"、"已保存"），显示一会儿自动消失
public struct EditorToast: Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public var systemImage: String?

    public init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }
}

struct ToastView: View {
    let toast: EditorToast

    var body: some View {
        Label {
            Text(toast.text)
        } icon: {
            if let icon = toast.systemImage { Image(systemName: icon) }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCapsule()
        .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// 顶部提示条：出现后 1.8 秒自动消失，新的提示会替换旧的
    func editorToast(_ toast: Binding<EditorToast?>) -> some View {
        overlay(alignment: .top) {
            if let current = toast.wrappedValue {
                ToastView(toast: current)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .task(id: current.id) {
                        try? await Task.sleep(for: .seconds(1.8))
                        if toast.wrappedValue?.id == current.id { toast.wrappedValue = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast.wrappedValue)
    }

    /// 圆形玻璃按钮底（iOS 26+），更早的系统用材质
    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        if #available(iOS 26, *) {
            glassEffect(tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(), in: .circle)
        } else {
            background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.regularMaterial), in: Circle())
        }
    }

    /// 胶囊形玻璃底
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}
#endif
