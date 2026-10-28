package com.example.redact.core

import com.example.redact.core.rules.SensitiveTextScanner
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 返回 (类别, 命中原文) 列表，便于断言 */
private fun hits(text: String) = SensitiveTextScanner.scan(text).map { it.kind to text.substring(it.span.start, it.span.end) }

private fun expectHit(text: String, kind: FindingKind, value: String) {
    val found = hits(text)
    assertTrue(found.any { it.first == kind && it.second == value }, "$text 应命中 ${kind.label} $value，实际：$found")
}

class SensitiveTextScannerTest {
    @Test fun 手机号各种写法() {
        expectHit("电话13800138000", FindingKind.PHONE, "13800138000")
        expectHit("138 0013 8000", FindingKind.PHONE, "138 0013 8000")
        expectHit("138-0013-8000", FindingKind.PHONE, "138-0013-8000")
        expectHit("+86 13800138000", FindingKind.PHONE, "+86 13800138000")
        expectHit("１３８００１３８０００", FindingKind.PHONE, "１３８００１３８０００")   // 全角
        expectHit("138OO138OOO", FindingKind.PHONE, "138OO138OOO")                     // OCR 把 0 认成 O
    }

    @Test fun 相邻两个号码要分开() {
        val found = hits("13800138000 13900139000").filter { it.first == FindingKind.PHONE }.map { it.second }
        assertEquals(listOf("13800138000", "13900139000"), found)
    }

    @Test fun 银行卡分组显示() {
        expectHit("卡号 6222 0212 3456 7894", FindingKind.BANK_CARD, "6222 0212 3456 7894")
        expectHit("6222021234567894", FindingKind.BANK_CARD, "6222021234567894")
    }

    @Test fun 身份证校验码对错都要打码() {
        val ok = SensitiveTextScanner.scan("110101199003074514").first()
        assertTrue(ok.kind == FindingKind.ID_CARD && ok.confidence >= 0.9f)
        val wrong = SensitiveTextScanner.scan("110101199003074515").first()   // OCR 错一位
        assertTrue(wrong.kind == FindingKind.ID_CARD && wrong.confidence >= 0.5f)
    }

    @Test fun 车牌() {
        expectHit("京A12345", FindingKind.PLATE, "京A12345")
        expectHit("车牌号：粤B6C789 已登记", FindingKind.PLATE, "粤B6C789")
        expectHit("沪AD12345", FindingKind.PLATE, "沪AD12345")      // 新能源
        expectHit("浙A·88888", FindingKind.PLATE, "浙A·88888")
        assertTrue(hits("京ABCDEF").none { it.first == FindingKind.PLATE })
    }

    @Test fun 邮箱_IP_验证码_提及() {
        expectHit("联系 zhang.san@example.com 谢谢", FindingKind.EMAIL, "zhang.san@example.com")
        expectHit("服务器 192.168.1.20 宕机", FindingKind.IP_ADDRESS, "192.168.1.20")
        assertTrue(hits("版本 1.2.3.400").none { it.first == FindingKind.IP_ADDRESS })
        expectHit("您的验证码是 482913，5 分钟内有效", FindingKind.VERIFICATION_CODE, "482913")
        expectHit("@张三 下午开会", FindingKind.MENTION, "@张三")
    }

    @Test fun 链接与国际号码() {
        expectHit("详情见 https://example.com/a?b=1 。", FindingKind.LINK, "https://example.com/a?b=1")
        expectHit("官网 www.example.cn", FindingKind.LINK, "www.example.cn")
        expectHit("打开 example.com/order 查看", FindingKind.LINK, "example.com/order")
        expectHit("Call +1 415 555 0132", FindingKind.PHONE, "+1 415 555 0132")
        expectHit("(415) 555-0132", FindingKind.PHONE, "(415) 555-0132")
        assertTrue(hits("zhang.san@example.com").none { it.first == FindingKind.LINK })
        assertTrue(hits("README.md 和 photo.png").none { it.first == FindingKind.LINK })
    }

    @Test fun 订单号与长数字() {
        expectHit("订单号 USR12842NOkJBaj21779868107", FindingKind.KEYWORD_VALUE, "USR12842NOkJBaj21779868107")
        expectHit("SF1234567890123 已签收", FindingKind.ORDER_NUMBER, "SF1234567890123")
        expectHit("流水 2024092512345678", FindingKind.LONG_NUMBER, "2024092512345678")
    }

    @Test fun 关键词定位姓名和地址() {
        expectHit("收货人：张三", FindingKind.KEYWORD_VALUE, "张三")
        expectHit("地址: 北京市朝阳区某某路 88 号", FindingKind.KEYWORD_VALUE, "北京市朝阳区某某路 88 号")
        expectHit("Name: John Appleseed", FindingKind.KEYWORD_VALUE, "John Appleseed")
        expectHit("收件人　李四", FindingKind.KEYWORD_VALUE, "李四")   // 全角空格
        assertTrue(SensitiveTextScanner.isLabelOnly("收货人"))
        assertTrue(SensitiveTextScanner.isLabelOnly("联系电话："))
        assertFalse(SensitiveTextScanner.isLabelOnly("收货人：张三"))
    }

    @Test fun 普通文字不误报() {
        assertTrue(hits("今天下午三点开会，记得带电脑").isEmpty())
        assertTrue(hits("iPhone 17 Pro Max 256GB").isEmpty())
        assertTrue(hits("2024-09-25 14:30").isEmpty(), "${hits("2024-09-25 14:30")}")
        assertTrue(hits("¥ 1,299.00").isEmpty())
    }
}
