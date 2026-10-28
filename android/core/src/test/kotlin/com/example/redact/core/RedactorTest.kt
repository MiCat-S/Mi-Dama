package com.example.redact.core

import com.example.redact.core.render.RgbaImage
import com.example.redact.core.render.Redactor
import com.example.redact.core.render.argb
import com.example.redact.core.render.blue
import com.example.redact.core.render.green
import com.example.redact.core.render.red
import kotlin.math.abs
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

private val WHITE = argb(255, 255, 255)
private val BLACK = argb(0, 0, 0)

/** 白底测试图 */
internal fun makeImage(width: Int, height: Int, bg: Int = WHITE, draw: RgbaImage.() -> Unit = {}): RgbaImage {
    val img = RgbaImage(width, height)
    img.pixels.fill(bg)
    img.draw()
    return img
}

internal fun RgbaImage.fillRect(x: Int, y: Int, w: Int, h: Int, color: Int) {
    for (yy in maxOf(0, y) until minOf(height, y + h)) for (xx in maxOf(0, x) until minOf(width, x + w)) this[xx, yy] = color
}

/** 竖条纹模拟文字笔画（高对比、高频） */
private fun RgbaImage.stripes(x: Int, y: Int, w: Int, h: Int) {
    var xx = x
    while (xx < x + w) {
        fillRect(xx, y, minOf(3, x + w - xx), h, BLACK)
        xx += 6
    }
}

private fun luma(c: Int) = (red(c) + green(c) + blue(c)) / 3f

/** 某一行在 [x0, x1) 内的亮度标准差：越大说明原始笔画越清晰 */
private fun rowStd(img: RgbaImage, y: Int, x0: Int, x1: Int): Float {
    val vals = (x0 until x1).map { luma(img[it, y]) }
    val mean = vals.average().toFloat()
    return sqrt(vals.map { (it - mean) * (it - mean) }.average().toFloat())
}

private fun finding(kind: FindingKind, x: Int, y: Int, w: Int, h: Int, style: MaskStyle? = null) =
    Finding(kind, Rect(x.toFloat(), y.toFloat(), w.toFloat(), h.toFloat()), 1f, style = style)

class RedactorTest {
    @Test fun 贴边模糊不透出原图() {
        val src = makeImage(200, 100) { stripes(0, 70, 200, 30) }
        val f = finding(FindingKind.FACE, 0, 60, 200, 40, MaskStyle.BLUR)
        val out = Redactor().render(src, listOf(f))
        assertTrue(rowStd(src, 99, 20, 180) > 100)
        val after = rowStd(out, 99, 20, 180)
        assertTrue(after < 6, "最后一行仍可见笔画结构：std=$after")
    }

    @Test fun 后加模糊不会翻出先前的纯色遮挡() {
        val src = makeImage(200, 100) { stripes(20, 30, 160, 40) }
        val solid = finding(FindingKind.PHONE, 10, 25, 180, 50, MaskStyle.SOLID)
        val blur = finding(FindingKind.FACE, 0, 0, 200, 100, MaskStyle.BLUR)
        val out = Redactor().render(src, listOf(solid, blur))
        assertTrue(rowStd(out, 50, 60, 140) < 2)
    }

    @Test fun 纯色背景上抹除文字不留痕迹() {
        val bg = argb(237, 237, 237)
        val src = makeImage(200, 60, bg) { stripes(40, 20, 100, 20) }
        val f = finding(FindingKind.PHONE, 40, 20, 100, 20)
        assertEquals(MaskStyle.HIDE_TEXT, f.resolvedStyle)
        val out = Redactor().render(src, listOf(f))
        for (y in listOf(22, 30, 38)) {
            assertTrue(rowStd(out, y, 35, 145) < 1.5f)
            assertTrue(abs(red(out[90, y]) - red(bg)) < 2)
        }
    }

    @Test fun 打码区域以外的像素保持不变() {
        val src = makeImage(200, 100) { stripes(0, 0, 200, 100) }
        val f = finding(FindingKind.PHONE, 60, 40, 80, 20, MaskStyle.SOLID)
        val out = Redactor().render(src, listOf(f))
        // 外扩后区域约为 y 37...63；上下各留 3px 余量检查
        for (y in listOf(0, 20, 33, 67, 80, 99)) {
            for (x in 0 until 200 step 7) assertEquals(src[x, y], out[x, y], "($x,$y) 被改动")
        }
        assertTrue(out[100, 50] != src[100, 50] || out[101, 50] != src[101, 50])
    }

    @Test fun 复杂背景的抹除文字退回大块像素化() {
        val src = makeImage(200, 60) { stripes(0, 0, 200, 60) }
        val f = finding(FindingKind.PHONE, 40, 20, 100, 20)
        val out = Redactor().render(src, listOf(f))
        // 块大小 ≥ 8px：同一块内的相邻像素完全相同
        assertEquals(out[60, 30], out[61, 30])
        assertTrue(rowStd(out, 30, 45, 135) < rowStd(src, 30, 45, 135))
    }

    @Test fun 不读原图的效果无法还原() {
        // 同一区域、完全不同的原图内容 → 打码后区域内像素必须一模一样
        for (style in MaskStyle.entries.filter { it.ignoresSourcePixels }) {
            val a = makeImage(200, 100) { stripes(40, 30, 120, 40) }
            val b = makeImage(200, 100) { fillRect(50, 35, 60, 30, argb(51, 128, 230)) }
            val f = finding(FindingKind.PHONE, 40, 30, 120, 40, style)
            val outA = Redactor().render(a, listOf(f))
            val outB = Redactor().render(b, listOf(f))
            for (y in 32 until 68 step 3) {
                for (x in 42 until 158 step 5) assertEquals(outA[x, y], outB[x, y], "$style 在 ($x,$y) 泄露了原图")
            }
            assertEquals(a[5, 5], outA[5, 5])   // 区域外不受影响
        }
    }

    @Test fun 单处样式优先于全局样式() {
        val src = makeImage(200, 60) { stripes(0, 0, 200, 60) }
        val own = finding(FindingKind.PHONE, 10, 10, 60, 30, MaskStyle.SOLID)
        val follow = finding(FindingKind.PHONE, 120, 10, 60, 30)
        val out = Redactor(fillColor = argb(255, 0, 0)).render(src, listOf(own, follow), MaskStyle.RAINBOW_BARS)
        assertEquals(argb(255, 0, 0), out[40, 25])        // 自己指定了色块
        assertNotEquals(argb(255, 0, 0), out[150, 25])     // 跟随全局：彩虹条
    }

    @Test fun 没有勾选的区域不打码() {
        val src = makeImage(100, 50) { stripes(0, 0, 100, 50) }
        val f = finding(FindingKind.PHONE, 10, 10, 60, 20, MaskStyle.SOLID).copy(isEnabled = false)
        assertTrue(Redactor().render(src, listOf(f)).pixels.contentEquals(src.pixels))
    }

    @Test fun 同一区域每次渲染图案一致() {
        val src = makeImage(200, 100)
        for (style in listOf(MaskStyle.NOISE_BLOCK, MaskStyle.RAINBOW_GRID)) {
            val f = finding(FindingKind.FACE, 30, 20, 100, 60, style)
            assertTrue(Redactor().render(src, listOf(f)).pixels.contentEquals(Redactor().render(src, listOf(f)).pixels))
        }
    }

    @Test fun 大区域模糊也能盖住() {
        val src = makeImage(1200, 1200) { stripes(100, 100, 1000, 1000) }
        val f = finding(FindingKind.FACE, 100, 100, 1000, 1000, MaskStyle.BLUR)
        val out = Redactor().render(src, listOf(f))
        // 半径很大时整行会有平缓的明暗过渡（这是正常的高斯模糊），所以看相邻像素差：条纹结构必须消失
        val jumps = (200 until 1000).maxOf { abs(luma(out[it + 1, 600]) - luma(out[it, 600])) }
        assertTrue(jumps < 2, "相邻像素最大差 $jumps")
    }
}
