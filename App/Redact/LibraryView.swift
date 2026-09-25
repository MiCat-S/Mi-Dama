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
        .onChange(of: pickerItems) { _, picked in Task { await openPicked(picked) } }
        .task {
            if library.status == .notDetermined { await library.requestAccess() }
            launched = true
            if openLatestOnLaunch { openLatest(onlyIfNew: false) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, launched else { return }
            library.refreshStatus()
            if openLatestOnLaunch { openLatest(onlyIfNew: true) }
        }
    }

    // MARK: - 自动打开最新图片

    /// - Parameter onlyIfNew: 从后台回来时只在出现了新的待打码图片时才打开，避免用户退回相册后又被拉进去
    private func openLatest(onlyIfNew: Bool) {
        guard canAutoNavigate, let asset = library.latestUnprocessed() else { return }
        let id = asset.localIdentifier
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

    @ViewBuilder
    private var content: some View {
        switch library.status {
        case .notDetermined:
            onboarding
        case .denied, .restricted:
            deniedView
        default:
            VStack(spacing: 0) {
                if library.status == .limited { limitedBanner }
                Picker("范围", selection: $library.filter) {
                    ForEach(PhotoLibrary.Filter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                if library.assets.count == 0 {
                    emptyLibrary
                } else {
                    grid
                }
            }
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let side = (geo.size.width - 4) / 3
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(0..<library.assets.count, id: \.self) { index in
                        let asset = library.assets.object(at: index)
                        AssetCell(asset: asset, library: library, side: side,
                                  selectionIndex: selection.firstIndex(of: asset.localIdentifier))
                            .onTapGesture { tap(asset) }
                    }
                }
            }
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
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
        }
    }

    // MARK: - 权限状态

    private var onboarding: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
            Text("自动找出截图里的敏感信息").font(.title3.bold())
            Text("允许访问相册后，打开 App 会直接进入最新的截图并开始识别。\n可以选择允许全部照片，或只允许部分照片。\n图片只在本机处理，不会上传。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("允许访问相册") { Task { await library.requestAccess(); openLatest(onlyIfNew: false) } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("没有相册访问权限").font(.title3.bold())
            Text("开启后，打开 App 会直接进入最新的截图。\n也可以不开启，每次手动选择图片。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("去设置开启") { openSettings() }.buttonStyle(.borderedProminent)
            Button("手动选择图片") { showPicker = true }.buttonStyle(.bordered)
        }
        .padding()
    }

    private var limitedBanner: some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text("只能看到你允许的照片").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("选择更多") { library.presentLimitedPicker() }.font(.footnote)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label(library.status == .limited ? "还没有允许访问的照片" : "相册里还没有图片", systemImage: "photo")
        } description: {
            Text(library.filter == .screenshots ? "截一张图后回到这里。" : "")
        } actions: {
            if library.status == .limited {
                Button("选择照片") { library.presentLimitedPicker() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxHeight: .infinity)
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

/// 相册网格里的一格：缩略图 + 多选序号 + "已打码"标记（本 App 导出的图）
private struct AssetCell: View {
    let asset: PHAsset
    let library: PhotoLibrary
    let side: CGFloat
    let selectionIndex: Int?
    @State private var image: UIImage?
    @State private var isOutput = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        Color.secondary.opacity(0.12)
            .frame(width: side, height: side)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if isOutput {
                    Text("已打码").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white).padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selectionIndex {
                    Text("\(selectionIndex + 1)").font(.caption.bold()).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Color.accentColor, in: Circle()).padding(4)
                }
            }
            .overlay {
                if selectionIndex != nil { Rectangle().stroke(Color.accentColor, lineWidth: 3) }
            }
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                image = await library.thumbnail(for: asset, side: side * scale)
                isOutput = PhotoLibrary.isRedactedOutput(asset)
            }
    }
}
