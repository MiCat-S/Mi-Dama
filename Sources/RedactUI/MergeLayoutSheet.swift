// 拼图的布局面板：上下 / 左右、间距、间距颜色、交换顺序。改动立即生效（可撤销），并记住作为下次拼图的默认
#if canImport(UIKit)
import RedactKit
import SwiftUI

struct MergeLayoutSheet: View {
    /// 面板高度：编辑页据此把画面缩到面板上方，改布局时能看到整张图
    static let height: CGFloat = 320

    let item: RedactItem
    let onEdit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("方向") {
                    picker(\.axis, MergeLayout.Axis.allCases, label: \.label)
                }
                LabeledContent("间距") {
                    picker(\.gap, MergeLayout.Gap.allCases, label: \.label)
                }
                LabeledContent("间距颜色") {
                    picker(\.background, MergeLayout.Background.allCases, label: \.label)
                }
                .disabled(layout.gap == .none)
                Button {
                    update { $0.order.reverse() }
                } label: {
                    Label("交换顺序", systemImage: layout.axis == .vertical ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                }
            }
            .disabled(item.isDetecting)
            .scrollDisabled(true)
            .contentMargins(.top, 4, for: .scrollContent)
            .navigationTitle("布局")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if item.isChangingLayout { ProgressView() }
                }
                ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } }
            }
        }
        .presentationDetents([.height(Self.height)])
        .presentationDragIndicator(.visible)
        // 不压暗背景：间距颜色、打码效果要看真实的样子
        .presentationBackgroundInteraction(.enabled(upThrough: .height(Self.height)))
    }

    /// 面板显示正在切换去的布局：连点时不会被还没切完的旧布局盖掉
    private var layout: MergeLayout {
        item.targetLayout ?? MergeLayout(axis: .vertical, order: [0, 1])
    }

    private func update(_ change: (inout MergeLayout) -> Void) {
        var next = layout
        change(&next)
        guard next != layout else { return }
        item.setMergeLayout(next)
        Preferences.rememberMergeLayout(next)
        onEdit()
    }

    private func picker<V: Hashable>(_ key: WritableKeyPath<MergeLayout, V>, _ values: [V],
                                     label: KeyPath<V, String>) -> some View {
        Picker("", selection: Binding(get: { layout[keyPath: key] }, set: { v in update { $0[keyPath: key] = v } })) {
            ForEach(values, id: \.self) { Text($0[keyPath: label]).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 168)
    }
}
#endif
