// 文本规则引擎：输入一行 OCR 文本，输出命中的敏感片段（原文字符范围）
// 纯函数、不依赖 Vision，方便单测
import Foundation

public struct TextMatch: Hashable, Sendable {
    public let kind: FindingKind
    /// 原文字符下标范围（Character 计数）
    public let range: Range<Int>
    public let confidence: Float
}

public enum SensitiveTextScanner {
    /// 扫描一行文本
    public static func scan(_ text: String) -> [TextMatch] {
        var candidates: [TextMatch] = []
        // 两遍：保留分隔符（能拆开相邻的两个号码）+ 去掉数字间分隔符（能命中分组显示的号码）
        for strip in [false, true] {
            let norm = Normalizer.normalize(text, stripSeparators: strip)
            let ns = norm.text as NSString
            for rule in rules where !strip || rule.matchesStrippedText {
                for m in rule.regex.matches(in: norm.text, range: NSRange(location: 0, length: ns.length)) {
                    let r = m.range(at: rule.group)
                    guard r.location != NSNotFound,
                          let conf = rule.confidence(ns.substring(with: r)),
                          let range = norm.originalRange(of: r) else { continue }
                    candidates.append(TextMatch(kind: rule.kind, range: range, confidence: conf))
                }
            }
        }
        candidates += dataDetectorMatches(text)
        if let value = keywordValueRange(in: text) {
            candidates.append(TextMatch(kind: .keywordValue, range: value, confidence: 0.75))
        }
        return deduplicate(candidates)
    }

    /// 整行只有一个标签（如 "收货人"），值在同一行右侧的另一段文字里
    public static func isLabelOnly(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let ns = t as NSString
        return labelOnlyRegex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil
    }

    // MARK: - 规则表

    private struct Rule {
        let kind: FindingKind
        let regex: NSRegularExpression
        /// 需要打码的捕获组（0 = 整个命中）
        var group = 0
        /// 兜底规则只在保留分隔符的文本上跑，否则 "2024-09-25 14:30" 会被拼成一串长数字
        var matchesStrippedText = true
        /// 返回 nil 表示不算命中
        let confidence: (String) -> Float?
    }

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let provinces = "京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼"

    /// 顺序即同置信度下的优先级
    private static let rules: [Rule] = [
        Rule(kind: .idCard,
             regex: re(#"(?<![0-9A-Za-z])[1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[0-9Xx](?![0-9A-Za-z])"#),
             confidence: { Validators.chineseIDChecksum($0) ? 0.95 : 0.7 }),
        Rule(kind: .phone,
             regex: re(#"(?<![0-9])(?:\+?86)?1[3-9]\d{9}(?![0-9])"#),
             confidence: { _ in 0.9 }),
        Rule(kind: .bankCard,
             regex: re(#"(?<![0-9])\d{15,19}(?![0-9])"#),
             confidence: { Validators.luhn($0) ? 0.9 : ($0.hasPrefix("62") ? 0.6 : nil) }),
        Rule(kind: .email,
             regex: re(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#),
             confidence: { _ in 0.95 }),
        Rule(kind: .plate,
             regex: re("[\(provinces)][A-HJ-NP-Z][·•\\s]?[A-HJ-NP-Z0-9]{4}[A-HJ-NP-Z0-9挂学警港澳]{1,2}(?![A-Za-z0-9])"),
             confidence: { s in s.filter(\.isASCIIDigit).count >= 2 ? 0.85 : nil }),
        Rule(kind: .ipAddress,
             regex: re(#"(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9.])"#),
             confidence: { Validators.isIPv4($0) ? 0.8 : nil }),
        Rule(kind: .verificationCode,
             regex: re(#"(?:验证码|校验码|动态码|动态密码|取件码|提货码|取餐码|verification code|passcode)[^0-9A-Za-z]{0,8}([0-9]{4,8})(?![0-9])"#, .caseInsensitive),
             group: 1,
             confidence: { _ in 0.85 }),
        Rule(kind: .phone,   // 座机
             regex: re(#"(?<![0-9])0\d{2,3}-?\d{7,8}(?![0-9])"#),
             confidence: { _ in 0.6 }),
        Rule(kind: .mention,
             regex: re(#"(?<![A-Za-z0-9._%+-])@[^\s@:：,，。!！?？]{1,20}"#),
             confidence: { _ in 0.7 }),
        Rule(kind: .orderNumber,   // 字母数字混合的长串：订单号、运单号、流水号
             regex: re(#"(?<![A-Za-z0-9])[A-Za-z0-9]{10,32}(?![A-Za-z0-9])"#),
             matchesStrippedText: false,
             confidence: { s in
                 let digits = s.filter(\.isASCIIDigit).count
                 return digits >= 4 && digits < s.count ? 0.55 : nil
             }),
        Rule(kind: .longNumber,    // 兜底：其他 10 位以上的纯数字
             regex: re(#"(?<![0-9])\d{10,}(?![0-9])"#),
             matchesStrippedText: false,
             confidence: { _ in 0.55 }),
    ]

    // MARK: - 关键词上下文

    /// 标签词：出现在行首时，把后面的值整段盖掉（正则抓不到的姓名、地址靠这个）
    private static let labels: [String] = [
        "收货人", "收件人", "寄件人", "联系人", "真实姓名", "姓名", "名字", "户名", "持卡人",
        "收货地址", "详细地址", "所在地区", "家庭住址", "住址", "地址",
        "身份证号码", "身份证号", "身份证", "证件号码", "证件号",
        "联系电话", "手机号码", "手机号", "手机", "电话",
        "银行卡号", "卡号", "账号", "账户", "开户行", "微信号", "支付宝账号", "支付宝", "QQ号", "QQ", "邮箱",
        "订单编号", "订单号", "运单号", "快递单号", "交易单号", "商户单号", "车牌号", "学号", "工号", "密码",
        "Name", "Full Name", "Address", "Phone", "Mobile", "Tel", "E-mail", "Email",
        "Account", "Card No", "Order No", "Order ID", "Tracking No", "Tracking Number", "Password",
    ].sorted { $0.count > $1.count }

    private static let labelAlternation = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")

    /// 标签 + 分隔符（冒号 / 空格）+ 值；或标签后直接跟数字 / 字母
    private static let keywordRegex = re(
        #"^\s*(?:"# + labelAlternation + #")(?:\s*[:：]\s*|\s+|(?=[0-9A-Za-z+]))(\S.*?)\s*$"#,
        .caseInsensitive
    )
    private static let labelOnlyRegex = re(#"^(?:"# + labelAlternation + #")\s*[:：]?$"#, .caseInsensitive)

    static func keywordValueRange(in text: String) -> Range<Int>? {
        let identity = NormalizedText(characters: Array(text), origin: Array(0..<text.count))
        let ns = text as NSString
        guard let m = keywordRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return identity.originalRange(of: m.range(at: 1))
    }

    // MARK: - 系统数据检测（国际格式电话、链接）

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
        | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    private static func dataDetectorMatches(_ text: String) -> [TextMatch] {
        guard let detector else { return [] }
        let identity = NormalizedText(characters: Array(text), origin: Array(0..<text.count))
        let ns = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let range = identity.originalRange(of: m.range) else { return nil }
            switch m.resultType {
            case .phoneNumber:
                // 太短的多半是时间、金额
                return ns.substring(with: m.range).filter(\.isNumber).count >= 7
                    ? TextMatch(kind: .phone, range: range, confidence: 0.75) : nil
            case .link:
                // 邮箱也会被识别成 mailto 链接，交给邮箱规则
                let text = ns.substring(with: m.range)
                if m.url?.scheme == "mailto" || text.contains("..") { return nil }
                return TextMatch(kind: .link, range: range, confidence: 0.6)
            default:
                return nil
            }
        }
    }

    // MARK: - 去重

    /// 高置信度优先；被已保留结果完全覆盖的丢弃，部分超出的保留（宁可多盖）
    private static func deduplicate(_ items: [TextMatch]) -> [TextMatch] {
        let sorted = items.enumerated().sorted { a, b in
            a.element.confidence != b.element.confidence ? a.element.confidence > b.element.confidence : a.offset < b.offset
        }.map(\.element)
        var kept: [TextMatch] = []
        var covered = IndexSet()
        for m in sorted {
            let r = IndexSet(integersIn: m.range)
            if covered.contains(integersIn: r) { continue }
            kept.append(m)
            covered.formUnion(r)
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
