// 文本规则引擎：输入一行 OCR 文本，输出命中的敏感片段（原文字符范围）
// 纯函数、不依赖 ML Kit，方便单测
//
// 正则里刻意不用 \d \s \S：Android 的正则基于 ICU，它们在 JVM 和 Android 上匹配的字符集不同，
// 这里统一写成显式字符类，两边行为一致（数字在归一化时已经转成半角）
package com.example.redact.core.rules

import com.example.redact.core.FindingKind
import com.example.redact.core.Span

data class TextMatch(
    val kind: FindingKind,
    /** 原文字符下标范围 */
    val span: Span,
    val confidence: Float,
)

object SensitiveTextScanner {
    /** 扫描一行文本 */
    fun scan(text: String): List<TextMatch> {
        val candidates = mutableListOf<TextMatch>()
        // 两遍：保留分隔符（能拆开相邻的两个号码）+ 去掉数字间分隔符（能命中分组显示的号码）
        for (strip in listOf(false, true)) {
            val norm = Normalizer.normalize(text, stripSeparators = strip)
            for (rule in rules) {
                if (strip && !rule.matchesStrippedText) continue
                for (m in rule.regex.findAll(norm.text)) {
                    val g = m.groups[rule.group] ?: continue
                    val conf = rule.confidence(g.value) ?: continue
                    val span = norm.originalSpan(g.range.first, g.range.last + 1) ?: continue
                    candidates += TextMatch(rule.kind, span, conf)
                }
            }
        }
        candidates += detectorMatches(text)
        keywordValueSpan(text)?.let { candidates += TextMatch(FindingKind.KEYWORD_VALUE, it, 0.75f) }
        return deduplicate(candidates, text.length)
    }

    /** 整行只有一个标签（如 "收货人"），值在同一行右侧的另一段文字里 */
    fun isLabelOnly(text: String) = labelOnlyRegex.matches(text.trim(*WHITESPACE))

    // 规则表

    private class Rule(
        val kind: FindingKind,
        val regex: Regex,
        /** 需要打码的捕获组（0 = 整个命中） */
        val group: Int = 0,
        /** 兜底规则只在保留分隔符的文本上跑，否则 "2024-09-25 14:30" 会被拼成一串长数字 */
        val matchesStrippedText: Boolean = true,
        /** 返回 null 表示不算命中 */
        val confidence: (String) -> Float?,
    )

    private val WHITESPACE = charArrayOf(' ', '\t', '\n', '\u000B', '\u000C', '\r', '\u00A0', '\u3000')
    private const val WS = "[ \\t\\n\\x0B\\f\\r\\u00A0\\u3000]"
    private const val NON_WS = "[^ \\t\\n\\x0B\\f\\r\\u00A0\\u3000]"

    private const val PROVINCES = "京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼"

    /** 顺序即同置信度下的优先级 */
    private val rules = listOf(
        Rule(
            FindingKind.ID_CARD,
            Regex("(?<![0-9A-Za-z])[1-9][0-9]{5}(?:18|19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9A-Za-z])"),
        ) { if (Validators.chineseIdChecksum(it)) 0.95f else 0.7f },
        Rule(FindingKind.PHONE, Regex("(?<![0-9])(?:\\+?86)?1[3-9][0-9]{9}(?![0-9])")) { 0.9f },
        Rule(FindingKind.BANK_CARD, Regex("(?<![0-9])[0-9]{15,19}(?![0-9])")) {
            if (Validators.luhn(it)) 0.9f else if (it.startsWith("62")) 0.6f else null
        },
        Rule(FindingKind.EMAIL, Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}")) { 0.95f },
        Rule(
            FindingKind.PLATE,
            Regex("[$PROVINCES][A-HJ-NP-Z][·• \\u3000]?[A-HJ-NP-Z0-9]{4}[A-HJ-NP-Z0-9挂学警港澳]{1,2}(?![A-Za-z0-9])"),
        ) { s -> if (s.count { it.isAsciiDigit() } >= 2) 0.85f else null },
        Rule(FindingKind.IP_ADDRESS, Regex("(?<![0-9.])(?:[0-9]{1,3}\\.){3}[0-9]{1,3}(?![0-9.])")) {
            if (Validators.isIPv4(it)) 0.8f else null
        },
        Rule(
            FindingKind.VERIFICATION_CODE,
            Regex(
                "(?:验证码|校验码|动态码|动态密码|取件码|提货码|取餐码|verification code|passcode)[^0-9A-Za-z]{0,8}([0-9]{4,8})(?![0-9])",
                RegexOption.IGNORE_CASE,
            ),
            group = 1,
        ) { 0.85f },
        // 座机
        Rule(FindingKind.PHONE, Regex("(?<![0-9])0[0-9]{2,3}-?[0-9]{7,8}(?![0-9])")) { 0.6f },
        Rule(FindingKind.MENTION, Regex("(?<![A-Za-z0-9._%+-])@[^ \\t\\n\\x0B\\f\\r\\u00A0\\u3000@:：,，。!！?？]{1,20}")) { 0.7f },
        // 字母数字混合的长串：订单号、运单号、流水号
        Rule(
            FindingKind.ORDER_NUMBER,
            Regex("(?<![A-Za-z0-9])[A-Za-z0-9]{10,32}(?![A-Za-z0-9])"),
            matchesStrippedText = false,
        ) { s ->
            val digits = s.count { it.isAsciiDigit() }
            if (digits >= 4 && digits < s.length) 0.55f else null
        },
        // 兜底：其他 10 位以上的纯数字
        Rule(FindingKind.LONG_NUMBER, Regex("(?<![0-9])[0-9]{10,}(?![0-9])"), matchesStrippedText = false) { 0.55f },
    )

    // 关键词上下文

    /** 标签词：出现在行首时，把后面的值整段盖掉（正则抓不到的姓名、地址靠这个） */
    private val labels = listOf(
        "收货人", "收件人", "寄件人", "联系人", "真实姓名", "姓名", "名字", "户名", "持卡人",
        "收货地址", "详细地址", "所在地区", "家庭住址", "住址", "地址",
        "身份证号码", "身份证号", "身份证", "证件号码", "证件号",
        "联系电话", "手机号码", "手机号", "手机", "电话",
        "银行卡号", "卡号", "账号", "账户", "开户行", "微信号", "支付宝账号", "支付宝", "QQ号", "QQ", "邮箱",
        "订单编号", "订单号", "运单号", "快递单号", "交易单号", "商户单号", "车牌号", "学号", "工号", "密码",
        "Name", "Full Name", "Address", "Phone", "Mobile", "Tel", "E-mail", "Email",
        "Account", "Card No", "Order No", "Order ID", "Tracking No", "Tracking Number", "Password",
    ).sortedByDescending { it.length }

    private val labelAlternation = labels.joinToString("|") { Regex.escape(it) }

    /** 标签 + 分隔符（冒号 / 空格）+ 值；或标签后直接跟数字 / 字母 */
    private val keywordRegex = Regex(
        "^$WS*(?:$labelAlternation)(?:$WS*[:：]$WS*|$WS+|(?=[0-9A-Za-z+]))($NON_WS.*?)$WS*$",
        RegexOption.IGNORE_CASE,
    )
    private val labelOnlyRegex = Regex("(?:$labelAlternation)$WS*[:：]?", RegexOption.IGNORE_CASE)

    internal fun keywordValueSpan(text: String): Span? {
        val g = keywordRegex.find(text)?.groups?.get(1) ?: return null
        return Span(g.range.first, g.range.last + 1)
    }

    // 链接、国际格式电话（iOS 版用系统的 NSDataDetector，这里用保守的正则代替）

    private const val TLDS = "com|cn|net|org|io|me|cc|top|xyz|edu|gov|info|co|app|dev|tv|hk|tw|jp|uk|us"
    private val linkRegex = Regex(
        "(?:https?://|www\\.)[^ \\t\\n\\x0B\\f\\r\\u00A0\\u3000<>\"'，。！？、；：（）【】「」]+" +
            "|(?<![A-Za-z0-9@._-])(?:[A-Za-z0-9-]+\\.)+(?:$TLDS)(?:/[^ \\t\\n\\x0B\\f\\r\\u00A0\\u3000<>\"'，。！？、；：（）【】「」]*)?(?![A-Za-z0-9@-])",
        RegexOption.IGNORE_CASE,
    )

    /** +国家码开头的号码，或 (555) 123-4567 / 555-123-4567 这类北美写法 */
    private val intlPhoneRegex = Regex(
        "(?<![0-9A-Za-z+])\\+[1-9][0-9]{0,2}(?:[ \\-]?\\(?[0-9]{1,4}\\)?){2,5}(?![0-9])" +
            "|(?<![0-9])\\(?[0-9]{3}\\)?[ .\\-][0-9]{3}[ .\\-][0-9]{4}(?![0-9])",
    )

    private fun detectorMatches(text: String): List<TextMatch> {
        val out = mutableListOf<TextMatch>()
        for (m in intlPhoneRegex.findAll(text)) {
            // 太短的多半是时间、金额
            if (m.value.count { it.isDigit() } in 7..15) {
                out += TextMatch(FindingKind.PHONE, Span(m.range.first, m.range.last + 1), 0.75f)
            }
        }
        for (m in linkRegex.findAll(text)) {
            if (m.value.contains("..")) continue
            out += TextMatch(FindingKind.LINK, Span(m.range.first, m.range.last + 1), 0.6f)
        }
        return out
    }

    // 去重

    /** 高置信度优先；被已保留结果完全覆盖的丢弃，部分超出的保留（宁可多盖） */
    private fun deduplicate(items: List<TextMatch>, length: Int): List<TextMatch> {
        val sorted = items.withIndex()
            .sortedWith(compareByDescending<IndexedValue<TextMatch>> { it.value.confidence }.thenBy { it.index })
            .map { it.value }
        val kept = mutableListOf<TextMatch>()
        val covered = BooleanArray(length)
        for (m in sorted) {
            val s = m.span.start.coerceIn(0, length)
            val e = m.span.end.coerceIn(s, length)
            if ((s until e).all { covered[it] }) continue
            kept += m
            for (i in s until e) covered[i] = true
        }
        return kept.sortedBy { it.span.start }
    }
}
