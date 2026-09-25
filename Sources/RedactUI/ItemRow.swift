// 列表里的一行：缩略图 + 识别状态 / 结果摘要（App 首页和分享扩展共用）
#if canImport(UIKit)
import RedactKit
import SwiftUI

public struct ItemRow: View {
    let item: RedactItem

    public init(item: RedactItem) {
        self.item = item
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: item.displayImage)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                switch item.phase {
                case .detecting:
                    Label("识别中…", systemImage: "hourglass")
                case .ready:
                    Text("发现 \(item.findings.count) 处，已勾选 \(item.enabledCount) 处")
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .saved:
                    Label("已保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .cancelled:
                    Label("已取消", systemImage: "xmark.circle").foregroundStyle(.secondary)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
    }

    private var summary: String {
        Dictionary(grouping: item.findings, by: \.kind)
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.label) \($0.value.count)" }
            .joined(separator: " · ")
    }
}
#endif
