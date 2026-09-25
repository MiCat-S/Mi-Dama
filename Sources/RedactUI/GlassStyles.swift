// Liquid Glass（iOS 26+）与旧系统的回退，集中在这里：
//  · 浮动控件用一整块玻璃，内容从下面滚过（不是占一条固定高度的不透明栏）
//  · 玻璃上面不再叠玻璃：面板里的类别标签等仍用实心浅色填充
//  · 「减少透明度」由系统材质自动处理
#if canImport(UIKit)
import SwiftUI

public enum PanelEdge {
    case top, bottom
}

extension View {
    /// 浮动控制面板：iOS 26+ 为带外边距的圆角玻璃；更早的系统退回贴边的系统栏材质
    @ViewBuilder
    public func floatingPanel(_ edge: PanelEdge, cornerRadius: CGFloat = 26) -> some View {
        if #available(iOS 26, *) {
            self
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .padding(.horizontal, 12)
                .padding(edge == .bottom ? .bottom : .top, 8)
        } else {
            self
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }

    /// 滚动内容底部的操作栏：iOS 26+ 用 safeAreaBar，内容从下面滚过时有系统的渐隐边缘；
    /// 不再额外套一层玻璃（弹出面板本身已经是玻璃，叠玻璃会影响可读性）
    @ViewBuilder
    public func bottomActionBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26, *) {
            // .hard：操作栏下方的内容明显压暗 / 模糊，玻璃按钮上的文字不会和列表内容混在一起
            self.safeAreaBar(edge: .bottom) { bar().padding() }
                .scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            self.safeAreaInset(edge: .bottom) { bar().padding().background(.bar) }
        }
    }

    /// 悬浮在内容上的小提示（如"识别中…"）
    @ViewBuilder
    public func glassBadge(cornerRadius: CGFloat = 16) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// 主要操作按钮（导出、保存）
    @ViewBuilder
    public func primaryActionStyle() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// 次要操作按钮（分享、全部导出）
    @ViewBuilder
    public func secondaryActionStyle() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
#endif
