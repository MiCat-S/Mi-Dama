// 相册页的各个部分：权限提示、受限访问横幅、照片网格（含空状态）、网格单元
import Photos
import RedactUI
import SwiftUI

/// 还没授权 / 被拒绝时显示的说明页
struct PermissionPromptView: View {
    enum Kind { case onboarding, denied }

    let kind: Kind
    let onRequestAccess: () -> Void
    let onOpenSettings: () -> Void
    let onPickManually: () -> Void
    /// 跟随系统字号缩放
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 60

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: kind == .onboarding ? "eye.slash.circle.fill" : "photo.badge.exclamationmark")
                .font(.system(size: iconSize))
                .foregroundStyle(kind == .onboarding ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(kind == .onboarding ? "自动找出截图里的敏感信息" : "没有相册访问权限")
                .font(.title3.bold())
            Text(kind == .onboarding
                 ? "允许访问相册后，打开 App 会直接进入最新的截图并开始识别。\n可以选择允许全部照片，或只允许部分照片。\n图片只在本机处理，不会上传。"
                 : "开启后，打开 App 会直接进入最新的截图。\n也可以不开启，每次手动选择图片。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            switch kind {
            case .onboarding:
                Button("允许访问相册", action: onRequestAccess).primaryActionStyle()
            case .denied:
                Button("去设置开启", action: onOpenSettings).primaryActionStyle()
                Button("手动选择图片", action: onPickManually).secondaryActionStyle()
            }
        }
        .padding()
    }
}

/// 受限访问：只看得到用户允许的照片
struct LimitedAccessBanner: View {
    let onChooseMore: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text("只能看到你允许的照片").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("选择更多", action: onChooseMore).font(.footnote)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }
}

/// 三列照片网格。网格始终存在，空相册时在上面叠一层空状态（视图树稳定，不来回替换）
struct PhotoGrid: View {
    let library: PhotoLibrary
    let selection: [String]
    let onTap: (PHAsset) -> Void

    var body: some View {
        GeometryReader { geo in
            let side = (geo.size.width - 4) / 3
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(library.assets) { entry in
                        AssetCell(asset: entry.asset, index: entry.index, library: library, side: side,
                                  selectionIndex: selection.firstIndex(of: entry.id))
                            .onTapGesture { onTap(entry.asset) }
                    }
                }
            }
        }
        .overlay {
            if library.assets.isEmpty {
                EmptyLibraryView(isLimited: library.status == .limited, filter: library.filter,
                                 onChooseMore: library.presentLimitedPicker)
            }
        }
    }
}

struct EmptyLibraryView: View {
    let isLimited: Bool
    let filter: PhotoLibrary.Filter
    let onChooseMore: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(isLimited ? "还没有允许访问的照片" : "相册里还没有图片", systemImage: "photo")
        } description: {
            Text(filter == .screenshots ? "截一张图后回到这里。" : "")
        } actions: {
            if isLimited {
                Button("选择照片", action: onChooseMore).primaryActionStyle()
            }
        }
    }
}

/// 网格里的一格：缩略图 + 多选序号 + "已打码"标记（本 App 导出的图）
struct AssetCell: View {
    let asset: PHAsset
    /// 在列表里的位置（预取前后的缩略图）
    let index: Int
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
                    // 缩略图尺寸固定，角标字号跟随系统但设上限，避免撑出格子
                    Text("已打码").font(.caption2.weight(.semibold)).dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .padding(.horizontal, 4).padding(.vertical, 1)
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(selectionIndex != nil ? [.isButton, .isSelected] : .isButton)
            .task(id: asset.localIdentifier) {
                guard !Task.isCancelled else { return }
                library.prefetchThumbnails(around: index, side: side * scale)
                image = await library.thumbnail(for: asset, side: side * scale)
                // 已经滑出屏幕：不用再查
                guard !Task.isCancelled else { return }
                isOutput = await library.isOutput(asset)
            }
    }

    private var accessibilityText: String {
        var parts: [String] = [asset.mediaSubtypes.contains(.photoScreenshot) ? "截图" : "照片"]
        if let date = asset.creationDate { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if isOutput { parts.append("已打码") }
        return parts.joined(separator: "，")
    }
}
