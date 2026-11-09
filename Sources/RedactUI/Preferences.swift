// 记住用户上次选的打码效果和颜色，以及哪些原图已经打过码
#if canImport(UIKit)
import CoreImage
import RedactKit
import SwiftUI

public enum Preferences {
    private static let styleKey = "maskStyle", colorKey = "maskColor"

    /// nil = 自动（按类别选默认效果）
    public static var style: MaskStyle? {
        get { MaskStyle(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "auto", forKey: styleKey) }
    }

    public static var colorHex: String {
        get { UserDefaults.standard.string(forKey: colorKey) ?? palette[0].hex }
        set { UserDefaults.standard.set(newValue, forKey: colorKey) }
    }

    private static let mergeLayoutKey = "mergeLayout"

    /// 拼图布局：在布局面板里改过就沿用上次的方向、间距、颜色（顺序总是按选图的顺序）；没改过按图片形状选
    public static func mergeLayout(for sizes: [CGSize]) -> MergeLayout {
        let order = Array(sizes.indices)
        if let data = UserDefaults.standard.data(forKey: mergeLayoutKey),
           var saved = try? JSONDecoder().decode(MergeLayout.self, from: data) {
            saved.order = order
            return saved
        }
        return MergeLayout(axis: MergeLayout.defaultAxis(for: sizes), order: order)
    }

    public static func rememberMergeLayout(_ layout: MergeLayout) {
        UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: mergeLayoutKey)
    }

    private static let processedKey = "processedAssets"

    /// 已经保存过打码版本的原图（localIdentifier），打开 App 时不再自动进入它们
    public static var processedAssets: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: processedKey) ?? [])
    }

    public static func markProcessed(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        var list = UserDefaults.standard.stringArray(forKey: processedKey) ?? []
        list.removeAll { identifiers.contains($0) }
        list += identifiers
        UserDefaults.standard.set(Array(list.suffix(500)), forKey: processedKey)
    }

    public static let palette: [(name: String, hex: String)] = [
        ("深灰", "#1C1C1E"), ("白", "#FFFFFF"), ("灰", "#8E8E93"), ("绿", "#34C759"),
        ("蓝", "#007AFF"), ("红", "#FF3B30"), ("黄", "#FFCC00"), ("紫", "#AF52DE"),
    ]
}

extension Color {
    public init(hex: String) {
        let c = CIColor.fromHex(hex)
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    public var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}
#endif
