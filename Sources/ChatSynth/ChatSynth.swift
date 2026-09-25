// 合成仿微信聊天截图 + 精确标注（头像 / 昵称 / 标题 / 系统消息），用来量化布局识别的召回率
// 只依赖 CoreGraphics / CoreText，macOS 与 iOS 都能跑
import CoreGraphics
import CoreText
import Foundation

public struct SynthConfig: Codable, Sendable {
    public var widthPx: Int = 1170
    public var scale: CGFloat = 3
    public var dark = false
    public var group = true
    public var circleAvatars = false
    public var seed: UInt64 = 1

    public init(widthPx: Int = 1170, scale: CGFloat = 3, dark: Bool = false, group: Bool = true,
                circleAvatars: Bool = false, seed: UInt64 = 1) {
        self.widthPx = widthPx; self.scale = scale; self.dark = dark
        self.group = group; self.circleAvatars = circleAvatars; self.seed = seed
    }
}

public struct SynthLabel: Codable, Sendable {
    public let kind: String    // avatar / nickname / title / system
    public let x: Double, y: Double, w: Double, h: Double
    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public struct SynthResult {
    public let image: CGImage
    public let labels: [SynthLabel]
}

public enum ChatSynth {
    public static func render(_ cfg: SynthConfig) -> SynthResult {
        var r = SplitMix64(seed: cfg.seed)
        let s = cfg.scale
        let W = CGFloat(cfg.widthPx) / s
        let H = (W * 2.165).rounded()
        let theme = Theme(dark: cfg.dark)
        let ctx = CGContext(data: nil, width: cfg.widthPx, height: Int(H * s), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // 左上原点、单位为 pt
        ctx.translateBy(x: 0, y: H * s)
        ctx.scaleBy(x: s, y: -s)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        var labels: [SynthLabel] = []
        func label(_ kind: String, _ rect: CGRect) {
            labels.append(SynthLabel(kind: kind, x: rect.minX * s, y: rect.minY * s, w: rect.width * s, h: rect.height * s))
        }

        fill(ctx, CGRect(x: 0, y: 0, width: W, height: H), theme.background)

        // 状态栏 + 导航栏
        _ = drawText(ctx, "9:41", font(16, bold: true), theme.text, at: CGPoint(x: 28, y: 16))
        fill(ctx, CGRect(x: W - 42, y: 20, width: 24, height: 11), theme.text, radius: 3)
        let members = r.int(3...200)
        let groupName = cfg.group ? r.pick(groupNames) + "(\(members))" : r.pick(names)
        let titleFont = font(17, bold: true)
        let tw = measure(groupName, titleFont).width
        label("title", drawText(ctx, groupName, titleFont, theme.text, at: CGPoint(x: (W - tw) / 2, y: 60)))
        strokeChevron(ctx, at: CGPoint(x: 14, y: 70), theme.text)
        for i in 0..<3 { fill(ctx, CGRect(x: W - 34 + CGFloat(i) * 7, y: 70, width: 4, height: 4), theme.text, radius: 2) }

        // 消息区
        let inputBarTop = H - 90
        var y: CGFloat = 108
        var senders: [(name: String, avatar: AvatarStyle)] = (0..<r.int(3...7)).map { _ in (r.pick(names), AvatarStyle.random(&r)) }
        let me = AvatarStyle.random(&r)
        while true {
            if r.chance(0.18) {
                let t = r.pick(["昨天 14:32", "上午 9:05", "星期二 21:17", "12:48"])
                let f = font(13)
                _ = drawText(ctx, t, f, theme.secondary, at: CGPoint(x: (W - measure(t, f).width) / 2, y: y))
                y += 32
            }
            if cfg.group, r.chance(0.08) {
                let t = r.chance(0.5) ? "“\(r.pick(names))”撤回了一条消息" : "“\(r.pick(names))”邀请“\(r.pick(names))”加入了群聊"
                let f = font(13)
                label("system", drawText(ctx, t, f, theme.secondary, at: CGPoint(x: (W - measure(t, f).width) / 2, y: y)))
                y += 32
            }

            let mine = r.chance(0.35)
            let sender: (name: String, avatar: AvatarStyle) = mine ? ("", me) : senders[r.int(0...(senders.count - 1))]
            let avatarRect = CGRect(x: mine ? W - 12 - 40 : 12, y: y, width: 40, height: 40)
            let text = r.pick(messages)
            let lines = wrap(text, font(17), maxWidth: W * 0.62)
            let bubbleW = min(W * 0.62, lines.map { measure($0, font(17)).width }.max() ?? 0) + 24
            let showName = cfg.group && !mine
            let bubbleTop = showName ? y + 20 : y
            let bubbleH = max(40, CGFloat(lines.count) * 24 + 16)
            if bubbleTop + bubbleH > inputBarTop - 8 { break }
            if showName {
                label("nickname", drawText(ctx, sender.name, font(12), theme.nickname, at: CGPoint(x: 62, y: y - 1)))
            }

            sender.avatar.draw(ctx, in: avatarRect, circle: cfg.circleAvatars, rng: &r)
            label("avatar", avatarRect)
            let bubble = CGRect(x: mine ? W - 62 - bubbleW : 62, y: bubbleTop, width: bubbleW, height: bubbleH)
            fill(ctx, bubble, mine ? theme.mine : theme.bubble, radius: 4)
            tail(ctx, bubble: bubble, mine: mine, color: mine ? theme.mine : theme.bubble)
            for (i, l) in lines.enumerated() {
                _ = drawText(ctx, l, font(17), mine && !cfg.dark ? theme.text : theme.bubbleText,
                             at: CGPoint(x: bubble.minX + 12, y: bubble.minY + 8 + CGFloat(i) * 24))
            }
            y = max(avatarRect.maxY, bubble.maxY) + 16
            if r.chance(0.1) { senders.append((r.pick(names), AvatarStyle.random(&r))) }
        }

        // 输入栏：图标都是描边圆，用来检验不会被误判成头像
        fill(ctx, CGRect(x: 0, y: inputBarTop, width: W, height: H - inputBarTop), theme.inputBar)
        fill(ctx, CGRect(x: 52, y: inputBarTop + 10, width: W - 144, height: 38), theme.inputField, radius: 6)
        for cx in [28, W - 72, W - 30] { strokeCircle(ctx, center: CGPoint(x: cx, y: inputBarTop + 29), radius: 14, theme.text) }

        return SynthResult(image: ctx.makeImage()!, labels: labels)
    }

    // MARK: - 主题

    struct Theme {
        let background, text, secondary, nickname, bubble, bubbleText, mine, inputBar, inputField: CGColor
        init(dark: Bool) {
            if dark {
                background = rgb(0x111111); text = rgb(0xD5D5D5); secondary = rgb(0x6B6B6B); nickname = rgb(0x7F7F7F)
                bubble = rgb(0x2C2C2C); bubbleText = rgb(0xD5D5D5); mine = rgb(0x3EB575); inputBar = rgb(0x1E1E1E); inputField = rgb(0x2C2C2C)
            } else {
                background = rgb(0xEDEDED); text = rgb(0x191919); secondary = rgb(0xB2B2B2); nickname = rgb(0x888888)
                bubble = rgb(0xFFFFFF); bubbleText = rgb(0x191919); mine = rgb(0x95EC69); inputBar = rgb(0xF7F7F7); inputField = rgb(0xFFFFFF)
            }
        }
    }

    // MARK: - 头像

    enum AvatarStyle {
        case initial(CGColor, String)
        case gradient(CGColor, CGColor)
        case mosaic([CGColor])
        case pale(String)          // 接近背景色的浅色头像：最难的情况

        static func random(_ r: inout SplitMix64) -> AvatarStyle {
            switch r.int(0...9) {
            case 0...3: return .initial(r.pick(palette), r.pick(["A", "王", "李", "Z", "陈", "M", "刘", "🐱"]))
            case 4...6: return .gradient(r.pick(palette), r.pick(palette))
            case 7...8: return .mosaic((0..<16).map { _ in r.pick(palette) })
            default: return .pale(r.pick(["林", "B", "周"]))
            }
        }

        func draw(_ ctx: CGContext, in rect: CGRect, circle: Bool, rng: inout SplitMix64) {
            ctx.saveGState()
            let path = circle ? CGPath(ellipseIn: rect, transform: nil)
                              : CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(path)
            ctx.clip()
            switch self {
            case .initial(let c, let ch):
                ctx.setFillColor(c); ctx.fill(rect)
                centered(ctx, ch, in: rect, color: rgb(0xFFFFFF))
            case .gradient(let a, let b):
                let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a, b] as CFArray, locations: nil)!
                ctx.drawLinearGradient(g, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
                ctx.setFillColor(rgb(0xF2D0B5))
                ctx.fillEllipse(in: rect.insetBy(dx: 11, dy: 9).offsetBy(dx: 0, dy: -2))   // 像一张脸的轮廓
            case .mosaic(let colors):
                let cell = rect.width / 4
                for (i, c) in colors.enumerated() {
                    ctx.setFillColor(c)
                    ctx.fill(CGRect(x: rect.minX + CGFloat(i % 4) * cell, y: rect.minY + CGFloat(i / 4) * cell, width: cell, height: cell))
                }
            case .pale(let ch):
                ctx.setFillColor(rgb(0xF4F4F4)); ctx.fill(rect)
                centered(ctx, ch, in: rect, color: rgb(0x9A9A9A))
            }
            ctx.restoreGState()
        }

        private func centered(_ ctx: CGContext, _ s: String, in rect: CGRect, color: CGColor) {
            let f = font(rect.height * 0.5, bold: true)
            let m = measure(s, f)
            _ = drawText(ctx, s, f, color, at: CGPoint(x: rect.midX - m.width / 2, y: rect.midY - m.height / 2))
        }
    }

    // MARK: - 绘制工具

    static func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateWithName((bold ? "PingFangSC-Medium" : "PingFangSC-Regular") as CFString, size, nil)
    }

    static func measure(_ s: String, _ f: CTFont) -> CGSize {
        let line = makeLine(s, f, rgb(0))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        return CGSize(width: w, height: ascent + descent)
    }

    /// 在左上角 `at` 处绘制一行文字，返回文字框（pt）
    static func drawText(_ ctx: CGContext, _ s: String, _ f: CTFont, _ color: CGColor, at p: CGPoint) -> CGRect {
        let line = makeLine(s, f, color)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ctx.textPosition = CGPoint(x: p.x, y: p.y + ascent)
        CTLineDraw(line, ctx)
        return CGRect(x: p.x, y: p.y, width: w, height: ascent + descent)
    }

    static func makeLine(_ s: String, _ f: CTFont, _ color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): f,
                                                    .init(kCTForegroundColorAttributeName as String): color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    static func wrap(_ s: String, _ f: CTFont, maxWidth: CGFloat) -> [String] {
        var lines: [String] = [], cur = ""
        for ch in s {
            if measure(cur + String(ch), f).width > maxWidth, !cur.isEmpty { lines.append(cur); cur = "" }
            cur.append(ch)
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    static func fill(_ ctx: CGContext, _ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    static func tail(_ ctx: CGContext, bubble: CGRect, mine: Bool, color: CGColor) {
        ctx.setFillColor(color)
        let x = mine ? bubble.maxX : bubble.minX, d: CGFloat = mine ? 6 : -6
        ctx.move(to: CGPoint(x: x, y: bubble.minY + 14))
        ctx.addLine(to: CGPoint(x: x + d, y: bubble.minY + 20))
        ctx.addLine(to: CGPoint(x: x, y: bubble.minY + 26))
        ctx.fillPath()
    }

    static func strokeCircle(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ color: CGColor) {
        ctx.setStrokeColor(color); ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    static func strokeChevron(_ ctx: CGContext, at p: CGPoint, _ color: CGColor) {
        ctx.setStrokeColor(color); ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: p.x + 8, y: p.y - 8)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x + 8, y: p.y + 8))
        ctx.strokePath()
    }

    // MARK: - 语料（全部为虚构数据）

    static let names = ["王小明", "李雷", "韩梅梅", "张伟", "陈静", "刘洋", "Alex", "小鱼儿🐟", "阿杰", "Momo",
                        "赵敏", "周周", "老林", "Kevin Z", "孙悦", "吴迪", "Lily", "大白", "郑一鸣", "黄小桃"]
    static let groupNames = ["项目讨论群", "家人群", "周末羽毛球", "产品评审", "三年二班家长群", "租房交流", "Design Crew"]
    static let messages = ["收到", "好的，我下午看一下", "明天上午十点开会，大家准时参加",
                           "我的手机号 13800138000，有事打我", "这个方案我觉得还可以再优化一下细节",
                           "发票抬头写公司全称就行", "谁有空帮忙取个快递，单号 SF1234567890123",
                           "哈哈哈哈", "👍", "@王小明 你看下这个", "地址：北京市朝阳区某某路 88 号",
                           "周末去爬山吗？天气预报说是晴天", "已转账，请查收", "我晚点到，你们先开始吧",
                           "文件已经发到邮箱 demo@example.com 了"]
    static let palette: [CGColor] = [0x4A90E2, 0xE94E77, 0x50C878, 0xF5A623, 0x9B59B6, 0x34495E, 0x1ABC9C, 0xE67E22, 0x7F8C8D, 0xC0392B].map(rgb)
}

func rgb(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// 可复现的随机数
public struct SplitMix64 {
    var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
}
