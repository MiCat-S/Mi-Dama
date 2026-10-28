// 识别总入口（纯逻辑部分）：OCR / 人脸 / 条码的原始结果 → 文本规则 → 聊天布局 → 合并去重
// ML Kit 调用在 App 里（见 MlKitDetector），这里只接收它的输出，方便单测
package com.example.redact.core.detect

import com.example.redact.core.Finding
import com.example.redact.core.FindingKind
import com.example.redact.core.Rect
import com.example.redact.core.Span
import com.example.redact.core.render.RgbaImage
import com.example.redact.core.rules.SensitiveTextScanner
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** 一行 OCR 文字（原图像素坐标，左上原点）：编辑器的"文字"工具点一下就能盖住整行 */
data class TextLine(val rect: Rect, val text: String)

/** 一行 OCR 结果 */
class RecognizedLine(
    val text: String,
    val confidence: Float,
    val rect: Rect,
    /** 每个字符（UTF-16 下标）的框，OCR 给不出时为 null */
    val charBoxes: List<Rect?>? = null,
) {
    /**
     * 字符范围 → 像素框。优先用 OCR 的字符框；没有字符框，或字符框明显不对（短短几个字却覆盖整行）时，
     * 按字符宽度比例在行框内插值
     */
    fun rectForCharacters(span: Span): Rect {
        if (text.isEmpty() || span.start < 0 || span.end > text.length || span.length <= 0) return rect
        if (span.length == text.length) return rect

        val boxes = charBoxes?.subList(span.start, span.end)?.filterNotNull()
        if (!boxes.isNullOrEmpty()) {
            val u = boxes.reduce(Rect::union)
            val coversWholeLine = u.width > rect.width * 0.9f
            val expectedFraction = weight(span.start, span.end) / weight(0, text.length)
            if (!coversWholeLine || expectedFraction > 0.8f) {
                // 横向用字符框并左右各留一点余量（OCR 的字符框常常比字形窄，比如 "1" 顶上那一撇会露出来）；
                // 纵向至少覆盖整行（"-"、"." 这类字符的框很矮）
                val slack = rect.height * 0.15f
                var x0 = u.minX - slack
                var x1 = u.maxX + slack
                // 紧挨着的是补回来的空格（位置来自像素上的空白）：不越过它，免得盖到旁边的字
                spaceX(span.start - 1)?.let { x0 = max(x0, it) }
                spaceX(span.end)?.let { x1 = min(x1, it) }
                return Rect.fromLTRB(x0, min(u.minY, rect.minY), x1, max(u.maxY, rect.maxY))
            }
        }
        // 兜底：按字符宽度插值（中文 1、半角 0.55），左右各留半个字的余量
        val total = weight(0, text.length)
        val x0 = rect.minX + rect.width * weight(0, span.start) / total
        val x1 = rect.minX + rect.width * weight(0, span.end) / total
        val slack = rect.width / total * 0.5f
        return Rect.fromLTRB(max(rect.minX, x0 - slack), rect.minY, min(rect.maxX, x1 + slack), rect.maxY)
    }

    /** 第 i 个字符是补回来的空格时，它的位置（零宽框） */
    private fun spaceX(i: Int): Float? {
        if (i < 0 || i >= text.length || text[i] != ' ') return null
        val box = charBoxes?.getOrNull(i) ?: return null
        return if (box.width == 0f) box.x else null
    }

    private fun weight(from: Int, to: Int): Float {
        var w = 0f
        for (i in from until to) w += if (text[i].code < 128) 0.55f else 1f
        return w
    }

    companion object {
        /**
         * 由逐字的 OCR 结果拼出一行，并把空格补回来。
         * ML Kit 的中文识别会把整行当成一个词、吞掉所有空格（"@王小明 你看下这个" 变成 "@王小明你看下这个"），
         * 规则就分不清 @提及在哪里结束、两个相邻号码在哪里断开。两种线索任一成立就算空格：
         *  · 相邻两个字框之间的间距明显大于这一行的正常字距（字框是真实字形位置时）
         *  · 像素上这里有一段明显比字距宽的空白（[gapCenters]，见 [blankGapCenters]；字框只是把整行平均切开时靠它）
         */
        fun fromSymbols(
            symbols: List<Pair<String, Rect>>, confidence: Float, rect: Rect, gapCenters: List<Float> = emptyList(),
        ): RecognizedLine {
            val gaps = symbols.zipWithNext { a, b -> b.second.minX - a.second.maxX }
            val typical = gaps.sorted().getOrElse(gaps.size / 2) { 0f }.coerceAtLeast(0f)
            val threshold = max(rect.height * 0.3f, typical * 3)
            val text = StringBuilder()
            val boxes = mutableListOf<Rect?>()
            for ((i, sym) in symbols.withIndex()) {
                if (i > 0) {
                    val prev = symbols[i - 1].second
                    val blank = gapCenters.firstOrNull { it > prev.midX && it < sym.second.midX }
                    if (gaps[i - 1] > threshold || blank != null) {
                        // 空格记一个零宽框，标出它的真实位置
                        val x = blank ?: ((prev.maxX + sym.second.minX) / 2)
                        text.append(' ')
                        boxes += Rect(x, rect.y, 0f, rect.height)
                    }
                }
                text.append(sym.first)
                repeat(sym.first.length) { boxes += sym.second }
            }
            return RecognizedLine(text.toString(), confidence, rect, boxes)
        }

        /**
         * 行框内比正常字距宽得多的空白列（空格）的中心 x（[img] 坐标）。
         * 背景取行框外一圈的中位色，和背景差得多的像素算笔画；一整列都没有笔画就是空白列。
         * 空白宽于 0.25 倍行高才算空格：中文字距、"小" "儿" 这类字内部的空隙都比它窄
         */
        fun blankGapCenters(img: RgbaImage, rect: Rect): List<Float> {
            val bg = img.ringStats(rect, band = 2)?.median ?: return emptyList()
            val x0 = max(0, rect.minX.toInt())
            val x1 = min(img.width, ceil(rect.maxX).toInt())
            val y0 = max(0, rect.minY.toInt())
            val y1 = min(img.height, ceil(rect.maxY).toInt())
            val minWidth = rect.height * 0.25f
            val centers = mutableListOf<Float>()
            var runStart = -1
            var seenInk = false
            for (x in x0..x1) {
                val blank = x == x1 || (y0 until y1).none { bg.maxDiff(img[x, it]) > 48 }
                if (blank && x < x1) {
                    if (runStart < 0) runStart = x
                } else {
                    // 行首、行尾的空白不算（那是行框的留白）
                    if (runStart >= 0 && seenInk && x < x1 && x - runStart >= minWidth) centers += (runStart + x) / 2f
                    runStart = -1
                    if (x < x1) seenInk = true
                }
            }
            return centers
        }
    }
}

/** OCR、人脸、条码的原始结果（原图像素坐标） */
class VisionResult(
    val lines: List<RecognizedLine> = emptyList(),
    val faces: List<Pair<Rect, Float>> = emptyList(),
    /** second：是否二维码 */
    val codes: List<Pair<Rect, Boolean>> = emptyList(),
)

class DetectionResult(val findings: List<Finding>, val textLines: List<TextLine>)

object DetectionPipeline {
    /** 布局分析用的工作宽度（约等于 1dp 一个像素，够用且快） */
    const val WORKING_WIDTH = 400f

    fun workingScale(imageWidth: Int) = min(1f, WORKING_WIDTH / imageWidth)

    /**
     * @param small 按 [workingScale] 缩小后的原图
     * @param width 原图宽
     * @param height 原图高
     */
    fun analyze(vision: VisionResult, small: RgbaImage, scale: Float, width: Int, height: Int): DetectionResult {
        val findings = textFindings(vision.lines).toMutableList()
        findings += vision.faces.map { (rect, conf) -> Finding(FindingKind.FACE, rect, max(0.6f, conf)) }
        findings += vision.codes.map { (rect, isQr) -> Finding(if (isQr) FindingKind.QR_CODE else FindingKind.BARCODE, rect, 0.9f) }

        val chat = ChatLayoutAnalyzer.analyze(small, scale, vision.lines, width.toFloat(), height.toFloat())
        findings += chat

        // 头像里的人脸交给头像处理，避免重复框
        val avatars = chat.filter { it.kind == FindingKind.CHAT_AVATAR }.map { it.rect }
        findings.removeAll { f ->
            f.kind == FindingKind.FACE && avatars.any { it.intersection(f.rect).area > f.rect.area * 0.6f }
        }
        val sorted = deduplicate(findings).sortedWith(compareBy({ it.rect.minY }, { it.rect.minX }))
        return DetectionResult(sorted, vision.lines.map { TextLine(it.rect, it.text) })
    }

    /** 文本规则命中 → 字符级框；"收货人" 这类单独一行的标签，把同一行右侧的文字当作值 */
    fun textFindings(lines: List<RecognizedLine>): List<Finding> {
        val out = mutableListOf<Finding>()
        for (line in lines) {
            for (m in SensitiveTextScanner.scan(line.text)) {
                // OCR 本身不确定时稍微降权，但仍在默认勾选线以上
                val conf = if (line.confidence < 0.5f) max(0.5f, m.confidence - 0.1f) else m.confidence
                val text = line.text.substring(m.span.start, m.span.end)
                out += Finding(m.kind, line.rectForCharacters(withEdgeNoise(line.text, m.span)), conf, text)
            }
            if (SensitiveTextScanner.isLabelOnly(line.text)) {
                val value = lines.filter { other ->
                    val overlap = min(other.rect.maxY, line.rect.maxY) - max(other.rect.minY, line.rect.minY)
                    other.rect.minX > line.rect.maxX && overlap > min(other.rect.height, line.rect.height) * 0.5f
                }.minByOrNull { it.rect.minX }
                if (value != null) out += Finding(FindingKind.KEYWORD_VALUE, value.rect, 0.7f, value.text)
            }
        }
        out += crossLineFindings(lines)
        return out
    }

    /**
     * 气泡里折行的邮箱、号码：把上下紧挨、左对齐的两行拼起来再扫一遍，
     * 只取跨越折行处的命中，两半各出一个框
     */
    fun crossLineFindings(lines: List<RecognizedLine>): List<Finding> {
        val sorted = lines.sortedBy { it.rect.minY }
        val out = mutableListOf<Finding>()
        for ((i, a) in sorted.withIndex()) {
            val b = sorted.drop(i + 1).firstOrNull { n ->
                n.rect.minY > a.rect.minY + a.rect.height * 0.5f &&
                    n.rect.minY - a.rect.maxY < a.rect.height * 0.6f &&
                    abs(n.rect.minX - a.rect.minX) < a.rect.height * 1.5f
            } ?: continue
            val joined = a.text + b.text
            val split = a.text.length
            for (m in SensitiveTextScanner.scan(joined)) {
                if (m.span.start >= split || m.span.end <= split) continue
                val text = joined.substring(m.span.start, m.span.end)
                out += Finding(m.kind, a.rectForCharacters(Span(m.span.start, split)), m.confidence, text)
                out += Finding(m.kind, b.rectForCharacters(Span(0, m.span.end - split)), m.confidence, text)
            }
        }
        return out
    }

    /**
     * 气泡边缘常被 OCR 认成紧贴着文字的 "|"，而且之后每个字的框都会往右错一位：
     * 命中范围紧挨着这类字符时把它一起算进去，宁可多盖一点气泡边缘
     */
    internal fun withEdgeNoise(text: String, span: Span): Span {
        var start = span.start
        var end = span.end
        while (start > 0 && text[start - 1] in EDGE_NOISE) start--
        while (end < text.length && text[end] in EDGE_NOISE) end++
        return Span(start, end)
    }

    private const val EDGE_NOISE = "|¦ǀ│"

    /** 同类且高度重叠的只留置信度最高的 */
    fun deduplicate(items: List<Finding>): List<Finding> {
        val kept = mutableListOf<Finding>()
        for (f in items.sortedByDescending { it.confidence }) {
            if (kept.any { it.kind == f.kind && it.rect.iou(f.rect) > 0.7f }) continue
            kept += f
        }
        return kept
    }
}
