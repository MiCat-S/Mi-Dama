package com.example.redact.core.render

import com.example.redact.core.Finding
import com.example.redact.core.Rect
import com.example.redact.core.detect.TextLine
import java.util.UUID
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

data class ImageSize(val width: Int, val height: Int)

data class MergeLayout(
    val axis: Axis,
    val gap: Gap = Gap.THIN,
    val background: Background = Background.WHITE,
    val order: List<Int> = listOf(0, 1),
) {
    enum class Axis(val label: String) { VERTICAL("上下"), HORIZONTAL("左右") }
    enum class Gap(val label: String, val fraction: Double) { NONE("无", 0.0), THIN("细", 0.02), THICK("粗", 0.05) }
    enum class Background(val label: String, val color: Int) { WHITE("白", -1), BLACK("黑", -0x1000000) }
    companion object {
        fun defaultAxis(sizes: List<ImageSize>) = if (sizes.all { it.height > it.width }) Axis.HORIZONTAL else Axis.VERTICAL
    }
}

/** Integer tile boundaries, indexed by source identity rather than display order. */
class Composition(val partSizes: List<ImageSize>, layout: MergeLayout, maxPixels: Int = 24_000_000) {
    val layout = if (layout.order.sorted() == partSizes.indices.toList()) layout else layout.copy(order = partSizes.indices.toList())
    val frames: List<Rect>
    val canvasSize: ImageSize
    init {
        require(partSizes.isNotEmpty() && partSizes.all { it.width > 0 && it.height > 0 })
        val vertical = layout.axis == MergeLayout.Axis.VERTICAL
        val rawCommon = partSizes.minOf { if (vertical) it.width else it.height }.toDouble()
        fun lengths(common: Double) = partSizes.map { if (vertical) it.height * common / it.width else it.width * common / it.height }
        fun gap(common: Double, lengths: List<Double>) = if (partSizes.size > 1) (min(common, lengths.min()) * layout.gap.fraction).roundToInt() else 0
        val rawLengths = lengths(rawCommon)
        val rawLength = rawLengths.sum() + gap(rawCommon, rawLengths) * (partSizes.size - 1)
        val scale = min(1.0, sqrt(maxPixels / (rawCommon * rawLength)))
        val common = floor(rawCommon * scale).coerceAtLeast(1.0)
        val lengths = lengths(common).map { it.roundToInt().coerceAtLeast(1).toDouble() }
        val gap = gap(common, lengths)
        val frames = MutableList(partSizes.size) { Rect.EMPTY }
        var cursor = 0f
        for (i in this.layout.order) {
            frames[i] = if (vertical) Rect(0f, cursor, common.toFloat(), lengths[i].toFloat())
                else Rect(cursor, 0f, lengths[i].toFloat(), common.toFloat())
            cursor += lengths[i].toFloat() + gap
        }
        this.frames = frames
        canvasSize = if (vertical) ImageSize(common.toInt(), (cursor - gap).toInt()) else ImageSize((cursor - gap).toInt(), common.toInt())
    }

    fun toCanvas(rect: Rect, part: Int): Rect {
        val f = frames[part]
        val s = partSizes[part]
        return Rect(f.x + rect.x * f.width / s.width, f.y + rect.y * f.height / s.height,
            rect.width * f.width / s.width, rect.height * f.height / s.height)
    }

    fun toParts(rect: Rect): List<Pair<Int, Rect>> = frames.mapIndexedNotNull { i, f ->
        val r = rect.intersection(f)
        if (r.isEmpty) null else {
            val s = partSizes[i]
            i to Rect((r.x - f.x) * s.width / f.width, (r.y - f.y) * s.height / f.height,
                r.width * s.width / f.width, r.height * s.height / f.height)
        }
    }

    fun findings(parts: List<List<Finding>>) = parts.flatMapIndexed { i, list -> list.map { it.copy(rect = toCanvas(it.rect, i)) } }
    fun textLines(parts: List<List<TextLine>>) = parts.flatMapIndexed { i, list -> list.map { it.copy(rect = toCanvas(it.rect, i)) } }
    fun remap(findings: List<Finding>, to: Composition): List<Finding> {
        require(partSizes == to.partSizes)
        return findings.flatMap { f -> toParts(f.rect).mapIndexed { n, (part, rect) ->
            f.copy(rect = to.toCanvas(rect, part), id = if (n == 0) f.id else UUID.randomUUID().toString())
        } }
    }

    /** Provider releases each source before the next is loaded. Sampling never crosses a tile edge. */
    fun compose(source: (Int) -> RgbaImage): RgbaImage {
        val out = RgbaImage(canvasSize.width, canvasSize.height)
        out.pixels.fill(layout.background.color)
        for (i in frames.indices) {
            val image = source(i)
            val f = frames[i]
            val w = f.width.toInt(); val h = f.height.toInt()
            for (y in 0 until h) {
                val y0 = y.toLong() * image.height / h
                val y1 = ((y + 1L) * image.height / h).toInt().coerceAtLeast(y0.toInt() + 1)
                for (x in 0 until w) {
                    val x0 = x.toLong() * image.width / w
                    val x1 = ((x + 1L) * image.width / w).toInt().coerceAtLeast(x0.toInt() + 1)
                    out[f.x.toInt() + x, f.y.toInt() + y] = image.average(x0.toInt(), y0.toInt(), x1, y1)
                }
            }
        }
        return out
    }
}
