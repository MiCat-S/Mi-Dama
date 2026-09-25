// 数据模型：一次识别的产出是一组 Finding，UI 负责让用户确认，Redactor 负责打码
import CoreGraphics
import Foundation

/// 敏感信息类别
public enum FindingKind: String, Codable, CaseIterable, Sendable {
    // 文字类
    case phone, idCard, bankCard, email, plate, ipAddress
    case verificationCode, longNumber, orderNumber, link, mention
    case keywordValue   // "收货人：张三" 这类由关键词定位到的值
    // 图像类
    case face, qrCode, barcode
    // 聊天截图布局类
    case chatAvatar, chatNickname, chatTitle, chatSystemMessage
    // 用户手动框选
    case manual

    /// 审核页展示用的中文名
    public var label: String {
        switch self {
        case .phone: "手机号"
        case .idCard: "身份证号"
        case .bankCard: "银行卡号"
        case .email: "邮箱"
        case .plate: "车牌"
        case .ipAddress: "IP 地址"
        case .verificationCode: "验证码"
        case .longNumber: "长数字"
        case .orderNumber: "订单/单号"
        case .link: "链接"
        case .mention: "@提及"
        case .keywordValue: "个人信息"
        case .face: "人脸"
        case .qrCode: "二维码"
        case .barcode: "条形码"
        case .chatAvatar: "头像"
        case .chatNickname: "昵称"
        case .chatTitle: "聊天标题"
        case .chatSystemMessage: "系统消息"
        case .manual: "手动"
        }
    }

    /// 是否属于文字（决定默认打码样式）
    public var isText: Bool {
        switch self {
        case .face, .qrCode, .barcode, .chatAvatar: false
        default: true
        }
    }
}

/// 一处待打码区域
public struct Finding: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: FindingKind
    /// 原图像素坐标，左上角为原点（与 UIKit / SwiftUI 一致）
    public var rect: CGRect
    /// 0–1，低于阈值的默认不勾选
    public var confidence: Float
    /// 命中的文字（仅用于审核页展示，不落盘、不打日志）
    public var text: String?
    public var isEnabled: Bool
    /// 单独指定的样式；nil 时用该类别的默认样式
    public var style: MaskStyle?

    public init(kind: FindingKind, rect: CGRect, confidence: Float, text: String? = nil,
                isEnabled: Bool? = nil, style: MaskStyle? = nil) {
        self.id = UUID()
        self.kind = kind
        self.rect = rect
        self.confidence = confidence
        self.text = text
        // 隐私工具宁可多盖：只有明显不可靠的结果默认不勾选
        self.isEnabled = isEnabled ?? (confidence >= 0.5)
        self.style = style
    }

    public var resolvedStyle: MaskStyle { style ?? .default(for: kind) }
}

/// 打码样式（声明顺序即界面上的排列顺序）
public enum MaskStyle: String, Codable, CaseIterable, Sendable {
    /// 背景近似纯色时用背景色把内容抹掉，否则退回大块像素化（不可逆）
    case hideText
    /// 纯色块
    case solid
    /// 带噪点的色块：比纯色块自然，同样不取原图像素
    case noiseBlock
    case pixelate
    case blur
    /// 横向彩虹条纹
    case rainbowBars
    /// 随机彩色方格：看起来像马赛克，但颜色与原图无关
    case rainbowGrid

    public var label: String {
        switch self {
        case .hideText: "抹除文字"
        case .solid: "色块"
        case .noiseBlock: "杂讯色块"
        case .pixelate: "像素化"
        case .blur: "模糊"
        case .rainbowBars: "彩虹条"
        case .rainbowGrid: "彩虹格"
        }
    }

    /// 是否使用用户选择的颜色
    public var usesColor: Bool { self == .solid || self == .noiseBlock }

    /// 结果只由区域大小和颜色决定、不读取原图像素 —— 无论强度如何都无法还原
    public var ignoresSourcePixels: Bool {
        switch self {
        case .solid, .noiseBlock, .rainbowBars, .rainbowGrid: true
        case .hideText, .pixelate, .blur: false
        }
    }

    /// 各类别的默认样式：文字用不可逆的抹除，人脸模糊，头像 / 二维码大块像素化
    public static func `default`(for kind: FindingKind) -> MaskStyle {
        switch kind {
        case .face: .blur
        case .chatAvatar, .qrCode, .barcode: .pixelate
        default: .hideText
        }
    }
}

extension CGRect {
    /// Core Image / Vision（左下原点）与 UIKit（左上原点）坐标互转，两个方向是同一个公式
    func flippedVertically(inHeight containerHeight: CGFloat) -> CGRect {
        CGRect(x: minX, y: containerHeight - maxY, width: width, height: height)
    }

    public var area: CGFloat { isNull ? 0 : width * height }

    /// 交并比
    public func iou(_ other: CGRect) -> CGFloat {
        let inter = intersection(other).area
        let union = area + other.area - inter
        return union > 0 ? inter / union : 0
    }
}
