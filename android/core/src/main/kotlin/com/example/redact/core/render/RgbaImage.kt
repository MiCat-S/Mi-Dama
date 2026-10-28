// CPU 侧像素：打码、布局分析、背景色采样都直接在 ARGB 整数数组上做，
// 不依赖 Android Bitmap，所以能在电脑上单测；App 里与 Bitmap 互转只是一次 getPixels / setPixels
package com.example.redact.core.render

import com.example.redact.core.Rect
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** sRGB 颜色，0–255 */
data class Rgb(val r: Float, val g: Float, val b: Float) {
    /** 三个通道里差得最多的那个 */
    fun maxDiff(argb: Int) = max(abs(red(argb) - r), max(abs(green(argb) - g), abs(blue(argb) - b)))

    fun maxDiff(o: Rgb) = max(abs(o.r - r), max(abs(o.g - g), abs(o.b - b)))

    fun toArgb() = argb(r.toInt().coerceIn(0, 255), g.toInt().coerceIn(0, 255), b.toInt().coerceIn(0, 255))

    companion object {
        fun of(argb: Int) = Rgb(red(argb).toFloat(), green(argb).toFloat(), blue(argb).toFloat())
    }
}

class RgbaImage(val width: Int, val height: Int, val pixels: IntArray = IntArray(width * height)) {
    init {
        require(pixels.size == width * height)
    }

    /** 第 0 行是图像顶部 */
    operator fun get(x: Int, y: Int) = pixels[y * width + x]

    operator fun set(x: Int, y: Int, argb: Int) {
        pixels[y * width + x] = argb
    }

    fun copy() = RgbaImage(width, height, pixels.copyOf())

    /** 面积平均缩小（布局分析用的小图） */
    fun scaled(scale: Float): RgbaImage {
        if (scale >= 1f) return copy()
        val w = max(1, (width * scale).toInt())
        val h = max(1, (height * scale).toInt())
        val out = RgbaImage(w, h)
        val sx = width.toFloat() / w
        val sy = height.toFloat() / h
        for (y in 0 until h) {
            val y0 = (y * sy).toInt()
            val y1 = max(y0 + 1, min(height, ((y + 1) * sy).toInt()))
            for (x in 0 until w) {
                val x0 = (x * sx).toInt()
                val x1 = max(x0 + 1, min(width, ((x + 1) * sx).toInt()))
                out[x, y] = average(x0, y0, x1, y1)
            }
        }
        return out
    }

    /** [x0, x1) × [y0, y1) 的平均色（调用方保证在图内且非空） */
    fun average(x0: Int, y0: Int, x1: Int, y1: Int): Int {
        var r = 0L
        var g = 0L
        var b = 0L
        for (y in y0 until y1) {
            var i = y * width + x0
            for (x in x0 until x1) {
                val c = pixels[i++]
                r += red(c); g += green(c); b += blue(c)
            }
        }
        val n = (x1 - x0).toLong() * (y1 - y0)
        return argb(((r + n / 2) / n).toInt(), ((g + n / 2) / n).toInt(), ((b + n / 2) / n).toInt())
    }

    class RingStats(val median: Rgb, val agreement: Float)

    /**
     * 矩形外一圈（宽 [band] 像素）的中位色，以及与中位色相差不超过 [tolerance] 的像素占比。
     * 用中位数 + 占比而不是最大偏差：JPEG 振铃、贴得很近的相邻文字只占一小部分，不该让整圈判为"不纯"
     */
    fun ringStats(rect: Rect, band: Int = 3, tolerance: Float = 18f): RingStats? {
        val x0 = floor(rect.minX).toInt() - band
        val x1 = ceil(rect.maxX).toInt() + band
        val y0 = floor(rect.minY).toInt() - band
        val y1 = ceil(rect.maxY).toInt() + band
        val xs0 = max(0, x0)
        val xs1 = max(xs0, min(width, x1))
        val ys0 = max(0, y0)
        val ys1 = max(ys0, min(height, y1))
        val samples = ArrayList<Int>()
        for (y in ys0 until ys1) {
            if (y < y0 + band || y >= y1 - band) {
                for (x in xs0 until xs1) samples += this[x, y]
            } else {
                // 中间的行只取左右两条边，不扫框内部
                for (x in max(xs0, x0) until min(xs1, x0 + band)) samples += this[x, y]
                for (x in max(xs0, x1 - band) until min(xs1, x1)) samples += this[x, y]
            }
        }
        if (samples.isEmpty()) return null
        val mid = samples.size / 2
        val median = Rgb(
            samples.map { red(it) }.sorted()[mid].toFloat(),
            samples.map { green(it) }.sorted()[mid].toFloat(),
            samples.map { blue(it) }.sorted()[mid].toFloat(),
        )
        val agree = samples.count { median.maxDiff(it) <= tolerance }
        return RingStats(median, agree.toFloat() / samples.size)
    }
}

fun red(argb: Int) = (argb shr 16) and 0xFF
fun green(argb: Int) = (argb shr 8) and 0xFF
fun blue(argb: Int) = argb and 0xFF
fun argb(r: Int, g: Int, b: Int) = (0xFF shl 24) or (r shl 16) or (g shl 8) or b

/** "#RRGGBB" ↔ ARGB */
object HexColor {
    fun parse(hex: String): Int = argb(0, 0, 0) or (hex.trim().removePrefix("#").toIntOrNull(16) ?: 0)

    fun format(argb: Int) = "#%02X%02X%02X".format(red(argb), green(argb), blue(argb))
}
