// 打码效果选择：每一项的缩略图都是用真实渲染器对一段示例号码打码的结果，所见即所得
#if canImport(UIKit)
import CoreImage
import RedactKit
import SwiftUI

struct EffectSheet: View {
    /// nil = 自动
    @Binding var style: MaskStyle?
    @Binding var colorHex: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(nil, title: "自动（推荐）", subtitle: "文字抹除、头像和二维码像素化、人脸模糊")
                    ForEach(MaskStyle.allCases, id: \.self) { s in
                        row(s, title: s.label, subtitle: Self.subtitle(s))
                    }
                } footer: {
                    Text("色块、杂讯色块、彩虹条、彩虹格不读取原图，任何情况下都无法还原。像素化和模糊用在文字上时，强度不足可能被辨认。长按图上的框可以给单独一处换效果。")
                }
                if style?.usesColor == true {
                    Section("颜色") { colorPalette }
                }
            }
            .navigationTitle("打码效果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ s: MaskStyle?, title: String, subtitle: String) -> some View {
        Button { style = s } label: {
            HStack(spacing: 12) {
                Image(uiImage: EffectPreview.image(s, colorHex: colorHex))
                    .resizable()
                    .frame(width: 112, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if style == s { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var colorPalette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Preferences.palette, id: \.hex) { c in
                    Circle()
                        .fill(Color(hex: c.hex))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 1))
                        .overlay(Circle().stroke(.tint, lineWidth: 3).padding(-4).opacity(colorHex == c.hex ? 1 : 0))
                        .onTapGesture { colorHex = c.hex }
                        .accessibilityLabel(c.name)
                }
                ColorPicker("自定义", selection: Binding(get: { Color(hex: colorHex) }, set: { colorHex = $0.hexString }),
                            supportsOpacity: false)
                    .labelsHidden()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    static func subtitle(_ s: MaskStyle) -> String {
        switch s {
        case .hideText: "背景是纯色时直接抹掉，看不出打过码"
        case .solid: "纯色遮挡"
        case .noiseBlock: "带颗粒的色块，比纯色自然"
        case .pixelate: "经典马赛克"
        case .blur: "高斯模糊"
        case .rainbowBars: "彩色横条"
        case .rainbowGrid: "彩色方格，颜色与原图无关"
        }
    }
}

/// 效果缩略图：示例文字"手机 138 0013 8000"，只对号码打码，标签保留 —— 一眼看出效果盖在哪
enum EffectPreview {
    private static let size = CGSize(width: 240, height: 60)
    private static let font = UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
    private static let label = "手机" as NSString, number = "138 0013 8000" as NSString
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// 号码所在的矩形（左上原点）
    private static let numberRect: CGRect = {
        let lw = label.size(withAttributes: [.font: font]).width
        let ns = number.size(withAttributes: [.font: font])
        return CGRect(x: 14 + lw + 8, y: (size.height - ns.height) / 2, width: ns.width, height: ns.height)
    }()

    private static let sample: CIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.94, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            label.draw(at: CGPoint(x: 14, y: numberRect.minY), withAttributes: attrs)
            number.draw(at: numberRect.origin, withAttributes: attrs)
        }
        return CIImage(cgImage: img.cgImage!)
    }()

    static func image(_ style: MaskStyle?, colorHex: String) -> UIImage {
        var redactor = Redactor(context: context)
        redactor.fillColor = .fromHex(colorHex)
        let finding = Finding(kind: .phone, rect: numberRect, confidence: 1)
        let out = redactor.render(sample, findings: [finding], style: style)
        guard let cg = redactor.makeCGImage(out) else { return UIImage() }
        return UIImage(cgImage: cg)
    }
}
#endif
