// 从相册 / 选择器打开图片：单张直接进审核页；多张在顶部缩略图条里切换，后台依次识别
import RedactUI
import SwiftUI

/// 读取图片（可能要从 iCloud 下载）后显示审核页；识别由审核页自己开始
struct ReviewContainer: View {
    let key: String
    let store: ItemStore
    @State private var item: RedactItem?
    @State private var failed = false

    var body: some View {
        Group {
            if let item {
                ReviewView(item: item)
            } else if failed {
                ContentUnavailableView("无法读取这张图片", systemImage: "exclamationmark.triangle",
                                       description: Text("图片可能已被删除，或还在从 iCloud 下载。"))
            } else {
                ProgressView("正在读取图片…")
            }
        }
        .task(id: key) {
            item = store.cached(key)
            if item == nil { item = await store.item(for: key) }
            failed = item == nil
        }
    }
}

struct BatchReviewView: View {
    let keys: [String]
    let store: ItemStore
    @State private var current: String
    /// 用 sheet(item:) 把要导出的图片随弹出一起传进去（isPresented 版本会拿到旧的空列表）
    @State private var exportRequest: ExportRequest?
    @State private var report: SaveReport?

    init(keys: [String], store: ItemStore) {
        self.keys = keys
        self.store = store
        _current = State(initialValue: keys.first ?? "")
    }

    var body: some View {
        ReviewContainer(key: current, store: store)
            .id(current)
            .safeAreaInset(edge: .top, spacing: 0) { strip }
            // 当前这张由审核页负责识别；其余的在后台依次识别，离开页面时自动停止
            .task {
                for key in keys {
                    if Task.isCancelled { break }
                    if let item = await store.item(for: key) {
                        await item.loadThumbnail()
                        await item.detectIfNeeded()
                    }
                }
            }
            .sheet(item: $exportRequest) { request in
                ExportSheet(items: request.items) { report = $0 }
            }
            .reportAlert($report)
            .sensoryFeedback(.selection, trigger: current)
    }

    private var strip: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(keys, id: \.self) { key in
                            BatchThumb(key: key, store: store, isCurrent: key == current)
                                .id(key)
                                .onTapGesture { current = key }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .onChange(of: current) { _, key in withAnimation { proxy.scrollTo(key, anchor: .center) } }
            }
            Button("全部导出") {
                Task {
                    var items: [RedactItem] = []
                    for key in keys { if let item = await store.item(for: key) { items.append(item) } }
                    exportRequest = ExportRequest(items: items)
                }
            }
            .secondaryActionStyle()
            .padding(.trailing, 12)
        }
        .floatingPanel(.top, cornerRadius: 22)
    }
}

private struct BatchThumb: View {
    let key: String
    let store: ItemStore
    let isCurrent: Bool
    @State private var item: RedactItem?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = item?.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 40, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
            status.padding(2)
        }
        .task {
            item = store.cached(key)
            if item == nil { item = await store.item(for: key) }
            await item?.loadThumbnail()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item?.phase {
        case .saved?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).font(.caption)
        case .failed?:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red).font(.caption)
        case .ready?:
            EmptyView()
        default:
            ProgressView().controlSize(.mini)
        }
    }
}
