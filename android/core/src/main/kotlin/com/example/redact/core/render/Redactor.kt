// 打码（与 iOS 版同样的四条原则）：
//  1. 每一处都从"当前结果"取像素 —— 后加的效果不会把之前盖住的内容翻出来
//  2. 采样越界时取最近的边缘像素 —— 贴边模糊不会透出原图
//  3. 强度随区域大小变化 —— 大图上的人脸、小字都能盖住
//  4. 色块 / 杂讯色块 / 彩虹条 / 彩虹格 只由区域位置和颜色生成，完全不读原图
package com.example.redact.core.render

import com.example.redact.core.Finding
import com.example.redact.core.FindingKind
import com.example.redact.core.MaskStyle
import com.example.redact.core.Rect
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

class Redactor(
    /** 色块、杂讯色块使用的颜色 */
    var fillColor: Int = argb(20, 20, 23),
) {
    /**
     * @param style 全局样式。优先级：单处指定的样式 > 全局样式 > 类别默认样式；null 表示"自动"
     * @return 新图，source 不变
     */
    fun render(source: RgbaImage, findings: List<Finding>, style: MaskStyle? = null): RgbaImage {
        val result = source.copy()
        val bounds = Rect(0f, 0f, source.width.toFloat(), source.height.toFloat())
        for (f in findings) {
            if (!f.isEnabled) continue
            val rect = padded(f).intersection(bounds)
            if (rect.isEmpty) continue
            val box = Box(
                floor(rect.minX).toInt(), floor(rect.minY).toInt(),
                min(source.width, ceil(rect.maxX).toInt()), min(source.height, ceil(rect.maxY).toInt()),
            )
            if (box.isEmpty) continue
            applyPatch(f.style ?: style ?: MaskStyle.defaultFor(f.kind), f.kind, rect, box, result, source)
        }
        return result
    }

    /** 整数像素框 [x0, x1) × [y0, y1) */
    private class Box(val x0: Int, val y0: Int, val x1: Int, val y1: Int) {
        val w get() = x1 - x0
        val h get() = y1 - y0
        val isEmpty get() = w <= 0 || h <= 0
    }

    /** 文字按行高外扩，盖住抗锯齿边缘和 OCR 框的误差 */
    private fun padded(f: Finding): Rect {
        val r = f.rect
        val pad = when {
            f.kind.isText -> max(2f, r.height * 0.12f)
            f.kind == FindingKind.FACE -> r.height * 0.1f
            else -> 1f
        }
        return r.inset(-pad, -pad)
    }

    private fun applyPatch(style: MaskStyle, kind: FindingKind, rect: Rect, box: Box, base: RgbaImage, source: RgbaImage) {
        val short = min(rect.width, rect.height)
        when (style) {
            MaskStyle.SOLID -> fill(base, box, fillColor)
            MaskStyle.HIDE_TEXT -> {
                // 背景足够纯：用背景色抹掉，看起来像原本没写字（从原图采样，不受之前打的码影响）
                val stats = source.ringStats(rect)
                if (stats != null && stats.agreement >= 0.7f) {
                    fill(base, box, stats.median.toArgb())
                } else {
                    // 背景复杂：退回大块像素化（每个字只剩 1–2 块，无法还原）
                    pixelate(base, box, max(8f, rect.height / 2))
                }
            }
            MaskStyle.PIXELATE -> pixelate(base, box, if (kind.isText) max(8f, rect.height / 2) else max(8f, short / 5))
            MaskStyle.BLUR -> blur(base, box, if (kind.isText) max(12f, rect.height) else max(16f, short / 4))
            MaskStyle.NOISE_BLOCK -> {
                // 颗粒约为区域短边的 1/12，亮度在 ±18% 内随机抖动
                val rng = SeededRandom(box.x0, box.y0)
                val (cols, rows) = grid(rect, max(2f, short / 12))
                val cells = IntArray(cols * rows) {
                    val k = rng.float(0.82f, 1.18f)
                    argb(
                        (red(fillColor) * k).roundToInt().coerceIn(0, 255),
                        (green(fillColor) * k).roundToInt().coerceIn(0, 255),
                        (blue(fillColor) * k).roundToInt().coerceIn(0, 255),
                    )
                }
                cellPatch(base, box, cells, cols, rows)
            }
            MaskStyle.RAINBOW_BARS -> cellPatch(base, box, RAINBOW, 1, RAINBOW.size)
            MaskStyle.RAINBOW_GRID -> {
                val rng = SeededRandom(box.x0, box.y0)
                val (cols, rows) = grid(rect, max(6f, short / if (kind.isText) 1.5f else 4f))
                val cells = IntArray(cols * rows)
                for (i in cells.indices) {
                    // 相邻两格不同色，格子才分得清
                    var c = RAINBOW[rng.int(RAINBOW.size)]
                    while (i > 0 && c == cells[i - 1]) c = RAINBOW[rng.int(RAINBOW.size)]
                    cells[i] = c
                }
                cellPatch(base, box, cells, cols, rows)
            }
        }
    }

    private fun fill(img: RgbaImage, box: Box, color: Int) {
        for (y in box.y0 until box.y1) img.pixels.fill(color, y * img.width + box.x0, y * img.width + box.x1)
    }

    /**
     * 方块网格以区域左上角为原点，像素按中心点归入方块（与 Core Image 的 CIPixellate 一致）；
     * 每块取整块（可伸出区域、不出图）的平均色，只写回区域内
     */
    private fun pixelate(img: RgbaImage, box: Box, block: Float) {
        fun edge(i: Int) = ceil(i * block - 0.5f).toInt()
        val cols = ceil(box.w / block).toInt() + 1
        val rows = ceil(box.h / block).toInt() + 1
        for (r in 0 until rows) {
            val by0 = box.y0 + edge(r)
            val by1 = min(img.height, box.y0 + edge(r + 1))
            for (c in 0 until cols) {
                val bx0 = box.x0 + edge(c)
                val bx1 = min(img.width, box.x0 + edge(c + 1))
                if (bx0 >= box.x1 || by0 >= box.y1 || bx1 <= bx0 || by1 <= by0) continue
                val color = img.average(bx0, by0, bx1, by1)
                for (y in by0 until min(by1, box.y1)) {
                    img.pixels.fill(color, y * img.width + bx0, y * img.width + min(bx1, box.x1))
                }
            }
        }
    }

    /**
     * 高斯模糊（sigma 约等于 [radius]），只写回区域内。大半径时先按 k 倍面积平均缩小、
     * 在小图上用三次盒式模糊逼近高斯，再双线性放大 —— 结果本来就很平滑，看不出差别，内存和耗时都小得多
     */
    private fun blur(img: RgbaImage, box: Box, radius: Float) {
        val k = max(1, (radius / 3).toInt())
        val margin = ceil(radius * 3 / k).toInt() * k
        val ox = box.x0 - margin
        val oy = box.y0 - margin
        val sw = ceil((box.w + 2 * margin).toFloat() / k).toInt()
        val sh = ceil((box.h + 2 * margin).toFloat() / k).toInt()
        val ch = Array(3) { FloatArray(sw * sh) }
        for (sy in 0 until sh) {
            for (sx in 0 until sw) {
                // 越界坐标夹到图内：相当于把边缘像素向外延展
                var r = 0f
                var g = 0f
                var b = 0f
                for (dy in 0 until k) {
                    val y = (oy + sy * k + dy).coerceIn(0, img.height - 1)
                    for (dx in 0 until k) {
                        val c = img[(ox + sx * k + dx).coerceIn(0, img.width - 1), y]
                        r += red(c); g += green(c); b += blue(c)
                    }
                }
                val n = (k * k).toFloat()
                val i = sy * sw + sx
                ch[0][i] = r / n; ch[1][i] = g / n; ch[2][i] = b / n
            }
        }
        val sigma = radius / k
        for (plane in ch) gaussian(plane, sw, sh, sigma)

        for (y in box.y0 until box.y1) {
            val fy = ((y - oy + 0.5f) / k - 0.5f).coerceIn(0f, sh - 1f)
            val y0 = fy.toInt()
            val y1 = min(sh - 1, y0 + 1)
            val ty = fy - y0
            for (x in box.x0 until box.x1) {
                val fx = ((x - ox + 0.5f) / k - 0.5f).coerceIn(0f, sw - 1f)
                val x0 = fx.toInt()
                val x1 = min(sw - 1, x0 + 1)
                val tx = fx - x0
                fun sample(p: FloatArray): Int {
                    val top = p[y0 * sw + x0] * (1 - tx) + p[y0 * sw + x1] * tx
                    val bottom = p[y1 * sw + x0] * (1 - tx) + p[y1 * sw + x1] * tx
                    return (top * (1 - ty) + bottom * ty).roundToInt().coerceIn(0, 255)
                }
                img[x, y] = argb(sample(ch[0]), sample(ch[1]), sample(ch[2]))
            }
        }
    }

    private fun grid(rect: Rect, cell: Float) =
        max(1, (rect.width / cell).roundToInt()) to max(1, (rect.height / cell).roundToInt())

    /** cols × rows 个颜色按最近邻铺满区域 */
    private fun cellPatch(img: RgbaImage, box: Box, cells: IntArray, cols: Int, rows: Int) {
        for (y in box.y0 until box.y1) {
            val row = min(rows - 1, (y - box.y0) * rows / box.h)
            for (x in box.x0 until box.x1) {
                val col = min(cols - 1, (x - box.x0) * cols / box.w)
                img[x, y] = cells[row * cols + col]
            }
        }
    }

    companion object {
        val RAINBOW = intArrayOf(0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x32ADE6, 0x007AFF, 0xAF52DE)
            .map { it or (0xFF shl 24) }.toIntArray()

        /** 三次盒式模糊逼近高斯（边缘取最近像素） */
        internal fun gaussian(p: FloatArray, w: Int, h: Int, sigma: Float) {
            if (sigma < 0.5f) return
            val tmp = FloatArray(p.size)
            for (r in boxRadii(sigma)) {
                boxPass(p, tmp, w, h, r, horizontal = true)
                boxPass(tmp, p, w, h, r, horizontal = false)
            }
        }

        /** 三个盒子的半径，使三次盒式模糊的方差等于 sigma²（Kovesi 的做法） */
        private fun boxRadii(sigma: Float): IntArray {
            val n = 3
            val wIdeal = sqrt(12 * sigma * sigma / n + 1)
            var wl = floor(wIdeal).toInt()
            if (wl % 2 == 0) wl--
            val wu = wl + 2
            val mIdeal = (12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4 * wl - 4)
            val m = mIdeal.roundToInt()
            return IntArray(n) { ((if (it < m) wl else wu) - 1) / 2 }
        }

        private fun boxPass(src: FloatArray, dst: FloatArray, w: Int, h: Int, r: Int, horizontal: Boolean) {
            val len = if (horizontal) w else h
            val lines = if (horizontal) h else w
            val step = if (horizontal) 1 else w
            val norm = 1f / (2 * r + 1)
            for (line in 0 until lines) {
                val start = if (horizontal) line * w else line
                fun at(i: Int) = src[start + i.coerceIn(0, len - 1) * step]
                var acc = 0f
                for (i in -r..r) acc += at(i)
                for (i in 0 until len) {
                    dst[start + i * step] = acc * norm
                    acc += at(i + r + 1) - at(i - r)
                }
            }
        }
    }
}

/** 以区域位置为种子的随机数：同一区域每次渲染图案一致（预览与导出一致），且与原图内容无关 */
internal class SeededRandom(x: Int, y: Int) {
    private var state: Long = (max(0, x).toLong() * 0x9E3779B97F4A7C15uL.toLong()) xor
        (max(0, y).toLong() * 0xBF58476D1CE4E5B9uL.toLong()) xor 0x94D049BB133111EBuL.toLong()

    fun next(): Long {
        state += 0x9E3779B97F4A7C15uL.toLong()
        var z = state
        z = (z xor (z ushr 30)) * 0xBF58476D1CE4E5B9uL.toLong()
        z = (z xor (z ushr 27)) * 0x94D049BB133111EBuL.toLong()
        return z xor (z ushr 31)
    }

    fun int(upper: Int) = java.lang.Long.remainderUnsigned(next(), upper.toLong()).toInt()

    fun float(lo: Float, hi: Float) = lo + java.lang.Long.remainderUnsigned(next(), 10_000L) / 10_000f * (hi - lo)
}
