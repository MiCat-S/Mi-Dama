import Testing
@testable import RedactKit

/// 返回 (类别, 命中原文) 列表，便于断言
private func hits(_ text: String) -> [(FindingKind, String)] {
    let chars = Array(text)
    return SensitiveTextScanner.scan(text).map { ($0.kind, String(chars[$0.range])) }
}

private func expectHit(_ text: String, _ kind: FindingKind, _ value: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let found = hits(text)
    #expect(found.contains { $0.0 == kind && $0.1 == value },
            "\(text) 应命中 \(kind.label) \(value)，实际：\(found)", sourceLocation: sourceLocation)
}

@Suite("文本规则")
struct SensitiveTextScannerTests {
    @Test func 手机号各种写法() {
        expectHit("电话13800138000", .phone, "13800138000")
        expectHit("138 0013 8000", .phone, "138 0013 8000")
        expectHit("138-0013-8000", .phone, "138-0013-8000")
        expectHit("+86 13800138000", .phone, "+86 13800138000")
        expectHit("１３８００１３８０００", .phone, "１３８００１３８０００")      // 全角
        expectHit("138OO138OOO", .phone, "138OO138OOO")                        // OCR 把 0 认成 O
    }

    @Test func 相邻两个号码要分开() {
        let found = hits("13800138000 13900139000").filter { $0.0 == .phone }.map(\.1)
        #expect(found == ["13800138000", "13900139000"])
    }

    @Test func 银行卡分组显示() {
        expectHit("卡号 6222 0212 3456 7894", .bankCard, "6222 0212 3456 7894")
        expectHit("6222021234567894", .bankCard, "6222021234567894")
    }

    @Test func 身份证校验码对错都要打码() {
        let ok = SensitiveTextScanner.scan("110101199003074514").first
        #expect(ok?.kind == .idCard && ok!.confidence >= 0.9)
        let wrong = SensitiveTextScanner.scan("110101199003074515").first   // OCR 错一位
        #expect(wrong?.kind == .idCard && wrong!.isEnabledByDefault)
    }

    @Test func 车牌() {
        expectHit("京A12345", .plate, "京A12345")
        expectHit("车牌号：粤B6C789 已登记", .plate, "粤B6C789")
        expectHit("沪AD12345", .plate, "沪AD12345")          // 新能源
        expectHit("浙A·88888", .plate, "浙A·88888")
        #expect(hits("京ABCDEF").allSatisfy { $0.0 != .plate })
    }

    @Test func 邮箱_IP_验证码_提及() {
        expectHit("联系 zhang.san@example.com 谢谢", .email, "zhang.san@example.com")
        expectHit("服务器 192.168.1.20 宕机", .ipAddress, "192.168.1.20")
        #expect(hits("版本 1.2.3.400").allSatisfy { $0.0 != .ipAddress })
        expectHit("您的验证码是 482913，5 分钟内有效", .verificationCode, "482913")
        expectHit("@张三 下午开会", .mention, "@张三")
    }

    @Test func 订单号与长数字() {
        expectHit("订单号 USR12842NOkJBaj21779868107", .keywordValue, "USR12842NOkJBaj21779868107")
        expectHit("SF1234567890123 已签收", .orderNumber, "SF1234567890123")
        expectHit("流水 2024092512345678", .longNumber, "2024092512345678")
    }

    @Test func 关键词定位姓名和地址() {
        expectHit("收货人：张三", .keywordValue, "张三")
        expectHit("地址: 北京市朝阳区某某路 88 号", .keywordValue, "北京市朝阳区某某路 88 号")
        expectHit("Name: John Appleseed", .keywordValue, "John Appleseed")
        #expect(SensitiveTextScanner.isLabelOnly("收货人"))
        #expect(SensitiveTextScanner.isLabelOnly("联系电话："))
        #expect(!SensitiveTextScanner.isLabelOnly("收货人：张三"))
    }

    @Test func 普通文字不误报() {
        #expect(hits("今天下午三点开会，记得带电脑").isEmpty)
        #expect(hits("iPhone 17 Pro Max 256GB").isEmpty)
        #expect(hits("2024-09-25 14:30").isEmpty)
    }
}

extension TextMatch {
    var isEnabledByDefault: Bool { confidence >= 0.5 }
}
