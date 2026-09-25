// 保存结果：弹窗文案 + 触感反馈（成功 / 部分成功 / 失败各用系统对应的触感）
#if canImport(UIKit)
import SwiftUI

public struct SaveReport: Identifiable, Equatable, Sendable {
    public enum Outcome: Sendable {
        /// 全部保存成功（包括用户自己在系统确认框里取消了删除原图）
        case success
        /// 图片已保存，但有部分没完成（中途出错、原图没删掉）
        case partial
        case failure
    }

    public let id = UUID()
    public let message: String
    public let outcome: Outcome

    public init(message: String, outcome: Outcome) {
        self.message = message
        self.outcome = outcome
    }

    var feedback: SensoryFeedback {
        switch outcome {
        case .success: .success
        case .partial: .warning
        case .failure: .error
        }
    }
}

/// 要导出的一批图片；用 sheet(item:) 弹出，保证弹窗拿到的就是点按钮那一刻的图片
public struct ExportRequest: Identifiable {
    public let id = UUID()
    public let items: [RedactItem]

    public init(items: [RedactItem]) {
        self.items = items
    }
}

extension View {
    /// 显示保存结果，并给出对应的触感反馈
    public func reportAlert(_ report: Binding<SaveReport?>) -> some View {
        alert(report.wrappedValue?.message ?? "", isPresented: Binding(
            get: { report.wrappedValue != nil },
            set: { if !$0 { report.wrappedValue = nil } }
        )) {
            Button("好") {}
        }
        .sensoryFeedback(trigger: report.wrappedValue) { _, new in new?.feedback }
    }
}
#endif
