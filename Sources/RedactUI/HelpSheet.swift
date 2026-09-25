// 「?」帮助：编辑页的手势和按钮说明
#if canImport(UIKit)
import SwiftUI

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let rows: [(icon: String, title: String, detail: String)] = [
        ("hand.tap", "点一下打码区域", "取消这一处，露出原图并留一圈虚线；再点一下恢复"),
        ("hand.point.up.left", "长按打码区域", "单独给这一处换效果，或删除手动加的框"),
        ("wand.and.sparkles", "左下角魔术棒", "点一下开 / 关全部自动打码；长按按类别开关"),
        ("textformat", "文字工具", "点一下任意一行文字，整行盖住；再点一下取消"),
        ("highlighter", "马克笔", "拖出一个框，盖住任意区域"),
        ("arrow.up.left.and.arrow.down.right", "双指缩放 / 双击", "放大看小字，双击在原大小和放大之间切换"),
        ("arrow.uturn.backward", "撤销 / 重做", "所有改动都可以撤销"),
        ("checkmark.circle.fill", "绿色对勾", "按当前导出设置直接存到相册"),
        ("square.and.arrow.up", "分享按钮", "选格式、大小、浮水印、是否删原图，再保存或分享"),
    ]

    var body: some View {
        NavigationStack {
            List(rows, id: \.title) { row in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.body.weight(.medium))
                        Text(row.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    // textformat 在中文环境会显示成"格式"，固定用英文字形 "Aa"
                    Image(systemName: row.icon).foregroundStyle(.tint)
                        .environment(\.locale, Locale(identifier: "en"))
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("怎么用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
