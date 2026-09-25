// 首页：选图（系统选择器，无需相册权限）→ 自动识别 → 列表里逐张审核或一键全部保存
import PhotosUI
import RedactKit
import SwiftUI

struct HomeView: View {
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var items: [RedactItem] = []
    @State private var savingAll = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    List(items) { item in
                        NavigationLink { ReviewView(item: item) } label: { row(item) }
                    }
                }
            }
            .navigationTitle("截图打码")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                        Label("选择图片", systemImage: "photo.badge.plus")
                    }
                }
                if items.contains(where: { $0.phase == .ready }) {
                    ToolbarItem(placement: .bottomBar) {
                        Button(savingAll ? "保存中…" : "全部保存到相册") { Task { await saveAll() } }
                            .disabled(savingAll)
                    }
                }
            }
            .onChange(of: pickerItems) { _, newValue in
                Task { await load(newValue) }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") {}
            }
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
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                Text("选择截图").frame(maxWidth: 220).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func row(_ item: RedactItem) -> some View {
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
                    Text(summary(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .saved:
                    Label("已保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
    }

    private func summary(_ item: RedactItem) -> String {
        Dictionary(grouping: item.findings, by: \.kind)
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.label) \($0.value.count)" }
            .joined(separator: " · ")
    }

    private func load(_ selection: [PhotosPickerItem]) async {
        guard !selection.isEmpty else { return }
        var loaded: [RedactItem] = []
        for p in selection {
            if let data = try? await p.loadTransferable(type: Data.self), let item = RedactItem(data: data) {
                loaded.append(item)
            }
        }
        items = loaded
        pickerItems = []
        await withTaskGroup(of: Void.self) { group in
            // 同时最多识别 2 张，避免大图把内存顶满
            var iterator = loaded.makeIterator()
            for _ in 0..<2 { if let item = iterator.next() { group.addTask { await item.detect() } } }
            while await group.next() != nil {
                if let item = iterator.next() { group.addTask { await item.detect() } }
            }
        }
    }

    private func saveAll() async {
        savingAll = true
        defer { savingAll = false }
        var saved = 0
        do {
            for item in items where item.phase == .ready {
                let export = item.export
                let data = try await Task.detached { try export.data() }.value
                try await PhotoSaver.save(data)
                item.phase = .saved
                saved += 1
            }
            message = "已保存 \(saved) 张"
        } catch {
            message = error.localizedDescription
        }
    }
}
