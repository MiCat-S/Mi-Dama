// 首页：选图（系统选择器，无需相册权限）→ 自动识别（带进度、可取消）→ 列表里逐张审核或一键全部保存
// 选择器绑定 .shared() 相册，才能拿到原图的 localIdentifier（"保存后删除原图"要用）
import PhotosUI
import RedactKit
import RedactUI
import SwiftUI

struct HomeView: View {
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var items: [RedactItem] = []
    @State private var message: String?
    @State private var detectTask: Task<Void, Never>?
    /// 识别进度；nil = 没有在识别
    @State private var detectProgress: (done: Int, total: Int)?
    /// 全部保存的进度；nil = 没有在保存
    @State private var saveProgress: (done: Int, total: Int)?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    List(items) { item in
                        if item.phase == .cancelled {
                            HStack {
                                ItemRow(item: item)
                                Spacer()
                                Button("重新识别") { Task { await item.detect() } }
                                    .buttonStyle(.bordered)
                            }
                        } else {
                            NavigationLink { ReviewView(item: item) } label: { ItemRow(item: item) }
                        }
                    }
                }
            }
            .navigationTitle("截图打码")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images, photoLibrary: .shared()) {
                        Label("选择图片", systemImage: "photo.badge.plus")
                    }
                }
                ToolbarItem(placement: .bottomBar) { bottomBar }
            }
            .onChange(of: pickerItems) { _, newValue in
                Task { await load(newValue) }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") {}
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let p = detectProgress {
            HStack(spacing: 12) {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    .frame(width: 120)
                Text("识别中 \(p.done)/\(p.total)").monospacedDigit()
                Button("取消", role: .cancel) { detectTask?.cancel() }
            }
        } else if let p = saveProgress {
            HStack(spacing: 12) {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    .frame(width: 120)
                Text("保存中 \(p.done)/\(p.total)").monospacedDigit()
            }
        } else if items.contains(where: { $0.phase == .ready }) {
            Button("全部保存到相册") { Task { await saveAll() } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("自动找出截图里的敏感信息")
                .font(.title3.bold())
            Text("手机号、身份证、银行卡、人脸、二维码、聊天头像和昵称……\n全部在本机识别，不联网、不上传。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images, photoLibrary: .shared()) {
                Text("选择截图").frame(maxWidth: 220).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func load(_ selection: [PhotosPickerItem]) async {
        guard !selection.isEmpty else { return }
        detectTask?.cancel()
        var loaded: [RedactItem] = []
        for p in selection {
            if let data = try? await p.loadTransferable(type: Data.self),
               let item = RedactItem(data: data, assetIdentifier: p.itemIdentifier) {
                loaded.append(item)
            }
        }
        items = loaded
        pickerItems = []
        let task = Task { await detectAll(loaded) }
        detectTask = task
        await task.value
    }

    /// 同时最多识别 2 张，避免大图把内存顶满。取消后正在识别的那张会跑完（Vision 请求无法中断），
    /// 还没开始的标为"已取消"
    private func detectAll(_ list: [RedactItem]) async {
        detectProgress = (0, list.count)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(2, list.count) {
                let item = list[next]
                next += 1
                group.addTask { await item.detect() }
            }
            while await group.next() != nil {
                detectProgress?.done += 1
                guard !Task.isCancelled, next < list.count else { continue }
                let item = list[next]
                next += 1
                group.addTask { await item.detect() }
            }
            for item in list[next...] { item.phase = .cancelled }
        }
        detectProgress = nil
    }

    private func saveAll() async {
        let targets = items.filter { $0.phase == .ready }
        saveProgress = (0, targets.count)
        defer { saveProgress = nil }
        var saved = 0
        var originals: [String] = []
        do {
            for item in targets {
                let export = item.export
                let data = try await Task.detached { try export.data() }.value
                try await PhotoSaver.save(data)
                item.phase = .saved
                saved += 1
                saveProgress?.done = saved
                if let id = item.assetIdentifier { originals.append(id) }
            }
        } catch {
            message = saved > 0 ? "已保存 \(saved) 张，之后出错：\(error.localizedDescription)" : error.localizedDescription
            return
        }
        // 全部保存成功后，一次性删除原图（系统只确认一次）
        var deletion: Result<PhotoSaver.DeleteOutcome, Error>?
        if ExportSettings.shared.deleteOriginal, !originals.isEmpty {
            do { deletion = .success(try await PhotoSaver.deleteOriginals(originals)) } catch { deletion = .failure(error) }
        }
        message = PhotoSaver.summary(saved: saved, deletion: deletion)
    }
}
