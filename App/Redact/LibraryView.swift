// 首页 = 相册：打开 App 直接进入最新一张待打码的图片（进入后自动识别），返回即是相册网格。
// 权限：系统弹窗里可选「完全访问 / 限制访问 / 不允许」；拒绝时仍可用系统选择器手动选图
import Photos
import PhotosUI
import RedactKit
import RedactUI
import SwiftUI

enum Route: Hashable {
    /// 一张时直接审核；多张时进入批量（顶部缩略图条切换）
    case review([String])
}

struct LibraryView: View {
    @State private var library = PhotoLibrary()
    @State private var store = ItemStore()
    @State private var path: [Route] = []
    @State private var selecting = false
    @State private var selection: [String] = []
    @State private var showPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var launched = false
    @AppStorage("openLatestOnLaunch") private var openLatestOnLaunch = true
    /// 上次自动打开的图片：从后台回来时只有出现了新图片才会再自动打开
    @AppStorage("lastAutoOpened") private var lastAutoOpened = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(selecting ? "已选 \(selection.count) 张" : "截图打码")
                .toolbar { toolbar }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .review(let keys) where keys.count == 1:
                        ReviewContainer(key: keys[0], store: store)
                    case .review(let keys):
                        BatchReviewView(keys: keys, store: store)
                    }
                }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 20,
                      matching: .images, photoLibrary: .shared())
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: pickerItems) { _, picked in Task { await openPicked(picked) } }
        .task {
            if library.status == .notDetermined { await library.requestAccess() }
            launched = true
            if openLatestOnLaunch { await openLatest(onlyIfNew: false) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, launched else { return }
            library.refreshStatus()
            if openLatestOnLaunch { Task { await openLatest(onlyIfNew: true) } }
        }
    }

    // MARK: - 自动打开最新图片

    /// - Parameter onlyIfNew: 从后台回来时只在出现了新的待打码图片时才打开，避免用户退回相册后又被拉进去
    private func openLatest(onlyIfNew: Bool) async {
        // 查找在后台进行，期间用户可能已经点进了别的图：找到后再确认一次
        guard canAutoNavigate, let id = await library.latestUnprocessed(), canAutoNavigate else { return }
        if onlyIfNew && id == lastAutoOpened { return }
        lastAutoOpened = id
        selecting = false
        path = [.review([id])]
    }

    /// 在相册页，或者正在看的那张已经保存过了，才允许自动跳转（不打断正在编辑的图）
    private var canAutoNavigate: Bool {
        guard !path.isEmpty else { return true }
        guard case .review(let keys)? = path.last, keys.count == 1,
              let item = store.cached(keys[0]) else { return false }
        return item.phase == .saved
    }

    // MARK: - 内容

    /// 权限状态决定整页内容：这是真正不同的三种页面，所以按状态切换
    @ViewBuilder
    private var content: some View {
        switch library.status {
        case .notDetermined:
            PermissionPromptView(kind: .onboarding, onRequestAccess: requestAccess,
                                 onOpenSettings: openSettings, onPickManually: { showPicker = true })
        case .denied, .restricted:
            PermissionPromptView(kind: .denied, onRequestAccess: requestAccess,
                                 onOpenSettings: openSettings, onPickManually: { showPicker = true })
        default:
            VStack(spacing: 0) {
                if library.status == .limited { LimitedAccessBanner(onChooseMore: library.presentLimitedPicker) }
                Picker("范围", selection: $library.filter) {
                    ForEach(PhotoLibrary.Filter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                PhotoGrid(library: library, selection: selection, onTap: tap)
            }
        }
    }

    private func requestAccess() {
        Task {
            await library.requestAccess()
            await openLatest(onlyIfNew: false)
        }
    }

    private func tap(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selecting {
            if let i = selection.firstIndex(of: id) { selection.remove(at: i) } else if selection.count < 20 { selection.append(id) }
        } else {
            path.append(.review([id]))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if library.isAuthorized {
            ToolbarItem(placement: .topBarLeading) {
                Button(selecting ? "取消" : "多选") {
                    selecting.toggle()
                    selection = []
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle("打开 App 时进入最新图片", isOn: $openLatestOnLaunch)
                Button("用系统选择器选图", systemImage: "photo.on.rectangle") { showPicker = true }
                if library.status == .limited {
                    Button("选择更多可访问的照片", systemImage: "plus.circle") { library.presentLimitedPicker() }
                }
                Button("照片访问权限设置", systemImage: "gear") { openSettings() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        if selecting {
            ToolbarItem(placement: .bottomBar) {
                Button("打码 \(selection.count) 张") {
                    let keys = selection
                    selecting = false
                    selection = []
                    path.append(.review(keys))
                }
                .primaryActionStyle()
                .disabled(selection.isEmpty)
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // MARK: - 系统选择器（没有相册权限时也能用）

    private func openPicked(_ picked: [PhotosPickerItem]) async {
        guard !picked.isEmpty else { return }
        pickerItems = []
        var keys: [String] = []
        for p in picked {
            guard let data = try? await p.loadTransferable(type: Data.self),
                  let item = RedactItem(data: data, assetIdentifier: p.itemIdentifier) else { continue }
            let key = p.itemIdentifier ?? "picked:\(item.id.uuidString)"
            store.register(item, key: key)
            keys.append(key)
        }
        guard !keys.isEmpty else { return }
        selecting = false
        path.append(.review(keys))
    }
}
