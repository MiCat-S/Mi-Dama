// 分享扩展界面：单张直接进审核页（保存即结束），多张先列表再逐张审核，或一次全部导出
import RedactUI
import SwiftUI

struct ShareRootView: View {
    @Bindable var model: ShareModel
    @State private var showExport = false

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { model.cancel() }
                    }
                }
        }
        .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") {}
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在读取图片…")
        case .empty:
            ContentUnavailableView("没有可打码的图片", systemImage: "photo.badge.exclamationmark",
                                   description: Text("请从「照片」或截图预览里分享图片。"))
        case .ready:
            if model.items.count == 1, let item = model.items.first {
                ReviewView(item: item, onSaved: { model.handleSaved($0) })
            } else {
                List(model.items) { item in
                    NavigationLink { ReviewView(item: item) } label: { ItemRow(item: item) }
                }
                .navigationTitle("截图打码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("全部导出") { showExport = true }
                            .disabled(model.items.contains { $0.isDetecting })
                    }
                }
                .sheet(isPresented: $showExport) {
                    ExportSheet(items: model.items) { model.handleSaved($0) }
                }
            }
        }
    }
}
