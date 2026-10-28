// OCR 文本归一化：让 "6222 0212 3456 7894"、"１３８ＯＯ１３８０００" 这类写法也能被规则命中，
// 同时记住每个归一化字符来自原文哪个字符，命中后能精确映射回字符框
package com.example.redact.core.rules

import com.example.redact.core.Span

internal class NormalizedText(
    /** 归一化后的文本 */
    val text: String,
    /** 归一化文本第 i 个字符 → 原文字符下标 */
    private val origin: IntArray,
) {
    /** 把一次正则命中（归一化文本上的 [start, end)）映射回原文字符范围 */
    fun originalSpan(start: Int, end: Int): Span? {
        if (start < 0 || end <= start || end > origin.size) return null
        return Span(origin[start], origin[end - 1] + 1)
    }

    companion object {
        fun identity(s: String) = NormalizedText(s, IntArray(s.length) { it })
    }
}

internal object Normalizer {
    /** 数字之间可以去掉的分组分隔符 */
    private val digitSeparators = setOf(' ', '　', '-', '－', '·', '•', '—', '_')

    /**
     * @param stripSeparators 是否去掉数字之间的分隔符。
     *   两种都要跑一遍：去掉能命中分组号码，不去掉才能把两个相邻号码分开。
     */
    fun normalize(s: String, stripSeparators: Boolean): NormalizedText {
        val chars = CharArray(s.length) { widen(s[it]) }
        val out = StringBuilder(chars.size)
        val origin = IntArray(chars.size)
        for (i in chars.indices) {
            var c = chars[i]
            val prev = out.lastOrNull()
            val next = chars.getOrNull(i + 1)

            // 数字上下文里的 OCR 形近字：一侧是数字、另一侧不是字母时才替换，避免破坏英文单词
            val fixed = digitLookalike(c)
            if (fixed != null) {
                val prevDigit = prev?.isAsciiDigit() == true
                val nextDigit = next?.isAsciiDigit() == true
                val prevLetter = prev?.isAsciiLetter() == true
                val nextLetter = next != null && next.isAsciiLetter() && digitLookalike(next) == null
                if ((prevDigit && !nextLetter) || (nextDigit && !prevLetter)) c = fixed
            }

            if (stripSeparators && c in digitSeparators && prev?.isAsciiDigit() == true &&
                next != null && isDigitOrLookalike(next)
            ) continue
            origin[out.length] = i
            out.append(c)
        }
        return NormalizedText(out.toString(), origin.copyOf(out.length))
    }

    /** 全角 → 半角（数字、字母、常用符号） */
    private fun widen(c: Char) = if (c in '！'..'～') (c.code - 0xFEE0).toChar() else c

    private fun digitLookalike(c: Char): Char? = when (c) {
        'O', 'o', '〇' -> '0'
        'l', 'I', '|', 'ǀ' -> '1'
        else -> null
    }

    private fun isDigitOrLookalike(c: Char) = c.isAsciiDigit() || digitLookalike(c) != null
}

internal fun Char.isAsciiDigit() = this in '0'..'9'
internal fun Char.isAsciiLetter() = this in 'a'..'z' || this in 'A'..'Z'
