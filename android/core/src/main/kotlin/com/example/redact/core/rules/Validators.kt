// 号码校验：命中校验的给高置信度，结构对但校验失败（常见于 OCR 错一位）的给中等置信度，照样打码
package com.example.redact.core.rules

internal object Validators {
    /** 18 位居民身份证校验码（GB 11643-1999） */
    fun chineseIdChecksum(id: String): Boolean {
        if (id.length != 18) return false
        val weights = intArrayOf(7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
        val checks = "10X98765432"
        var sum = 0
        for (i in 0 until 17) {
            val c = id[i]
            if (!c.isAsciiDigit()) return false
            sum += (c - '0') * weights[i]
        }
        return id[17].uppercaseChar() == checks[sum % 11]
    }

    /** Luhn（银行卡） */
    fun luhn(number: String): Boolean {
        var sum = 0
        for ((i, c) in number.reversed().withIndex()) {
            if (!c.isAsciiDigit()) return false
            var d = c - '0'
            if (i % 2 == 1) {
                d *= 2
                if (d > 9) d -= 9
            }
            sum += d
        }
        return sum % 10 == 0
    }

    fun isIPv4(s: String): Boolean {
        val parts = s.split('.')
        return parts.size == 4 && parts.all { p ->
            val n = p.toIntOrNull() ?: return@all false
            p.length <= 3 && n in 0..255 && !(p.length > 1 && p.startsWith("0"))
        }
    }
}
