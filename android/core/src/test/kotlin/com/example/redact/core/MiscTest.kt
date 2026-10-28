package com.example.redact.core

import com.example.redact.core.detect.DetectionPipeline
import com.example.redact.core.detect.RecognizedLine
import com.example.redact.core.detect.VisionResult
import com.example.redact.core.render.ExportSize
import com.example.redact.core.render.ImageKind
import com.example.redact.core.render.RgbaImage
import com.example.redact.core.render.argb
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class EditHistoryTest {
    @Test fun 撤销再重做回到原状态() {
        val h = EditHistory<Int>()
        var state = 0
        for (next in listOf(1, 2, 3)) {
            h.record(state, next)
            state = next
        }
        state = h.undo(state)!!   // 2
        state = h.undo(state)!!   // 1
        assertEquals(1, state)
        state = h.redo(state)!!   // 2
        assertEquals(2, state)
        assertTrue(h.canUndo && h.canRedo)
    }

    @Test fun 新编辑清空重做栈() {
        val h = EditHistory<Int>()
        h.record(0, 1)
        h.undo(1)
        assertTrue(h.canRedo)
        h.record(0, 5)
        assertFalse(h.canRedo)
    }

    @Test fun 没有变化不记录且有上限() {
        val h = EditHistory<Int>(limit = 3)
        h.record(7, 7)
        assertFalse(h.canUndo)
        for (i in 0 until 10) h.record(i, i + 1)
        assertEquals(listOf(7, 8, 9), h.undoStates)
    }

    @Test fun 识别框整体快照可以撤销() {
        val a = Finding(FindingKind.PHONE, Rect(0f, 0f, 10f, 10f), 0.9f)
        val h = EditHistory<List<Finding>>()
        val before = listOf(a)
        val after = listOf(a.copy(isEnabled = false))
        h.record(before, after)
        assertTrue(h.undo(after)!!.first().isEnabled)
    }
}

class ExportTest {
    @Test fun 限制长边只缩小不放大() {
        assertEquals(200 to 150, ExportSize.MaxSide(200).apply(400, 300))
        assertEquals(400 to 300, ExportSize.MaxSide(1000).apply(400, 300))
        assertEquals(400 to 300, ExportSize.Original.apply(400, 300))
        assertEquals(ExportSize.MaxSide(100), ExportSize.Original.capped(100))
        assertEquals(ExportSize.MaxSide(80), ExportSize.MaxSide(80).capped(100))
    }

    @Test fun 截图与照片的判断() {
        val png = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A)
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte())
        assertTrue(ImageKind.isLikelyScreenshot(png, null, hasCameraExposure = false))
        // 截图被转码成 JPEG 分享：没有快门 / 光圈
        assertTrue(ImageKind.isLikelyScreenshot(jpeg, null, hasCameraExposure = false))
        assertTrue(ImageKind.isLikelyScreenshot(jpeg, "Screenshot", hasCameraExposure = true))
        // 相机照片
        assertFalse(ImageKind.isLikelyScreenshot(jpeg, null, hasCameraExposure = true))
    }
}

class DetectionPipelineTest {
    private fun line(text: String, x: Float, y: Float, w: Float, h: Float = 40f) =
        RecognizedLine(text, 0.9f, Rect(x, y, w, h))

    @Test fun 字符框插值落在号码上() {
        val l = line("电话13800138000", 100f, 50f, 400f)
        val f = DetectionPipeline.textFindings(listOf(l)).single { it.kind == FindingKind.PHONE }
        assertTrue(f.rect.minX > 150f && f.rect.maxX <= 500f, "${f.rect}")
    }

    @Test fun 有字符框时用字符框() {
        val text = "卡号 6222021234567894"
        val boxes = text.indices.map { i -> if (text[i] == ' ') null else Rect(10f + i * 20f, 12f, 18f, 30f) }
        val l = RecognizedLine(text, 0.9f, Rect(10f, 10f, text.length * 20f, 34f), boxes)
        val f = DetectionPipeline.textFindings(listOf(l)).single { it.kind == FindingKind.BANK_CARD }
        // 字符框左右各留 15% 行高的余量
        assertEquals(10f + 3 * 20f - 34f * 0.15f, f.rect.minX, 0.01f)
        assertEquals(10f + (text.length - 1) * 20f + 18f + 34f * 0.15f, f.rect.maxX, 0.01f)
        assertEquals(10f, f.rect.minY)   // 纵向至少覆盖整行
    }

    @Test fun 按字间距补回OCR吞掉的空格() {
        // "@王小明 你看下这个"：字宽 30、字距 3，"明" 和 "你" 之间空出 15
        val chars = "@王小明你看下这个"
        var x = 0f
        val symbols = chars.mapIndexed { i, c ->
            if (i == 4) x += 12f
            val r = Rect(x, 0f, 30f, 32f)
            x += 33f
            c.toString() to r
        }
        val line = RecognizedLine.fromSymbols(symbols, 0.9f, Rect(0f, 0f, x, 32f))
        assertEquals("@王小明 你看下这个", line.text)
        val f = DetectionPipeline.textFindings(listOf(line)).single { it.kind == FindingKind.MENTION }
        assertEquals("@王小明", f.text)
        assertTrue(f.rect.maxX < 4 * 33f + 10f, "${f.rect}")
    }

    @Test fun 字框平均切开时按像素空白补回空格() {
        // 9 个字，字宽 40、字距 6，第 4 个字后面空出 24（空格）；OCR 给的字框却是把整行平均切开、首尾相接
        val img = makeImage(500, 80, argb(149, 236, 105))
        var x = 10
        for (i in 0 until 9) {
            img.fillRect(x, 20, 40, 40, argb(20, 20, 20))
            x += 40 + if (i == 3) 24 else 6
        }
        val lineRect = Rect(8f, 18f, (x - 6 - 8 + 2).toFloat(), 44f)
        val gaps = RecognizedLine.blankGapCenters(img, lineRect)
        assertEquals(1, gaps.size, "$gaps")
        val w = lineRect.width / 9
        val symbols = "@王小明你看下这个".mapIndexed { i, c -> c.toString() to Rect(lineRect.x + i * w, lineRect.y, w, lineRect.height) }
        val line = RecognizedLine.fromSymbols(symbols, 0.9f, lineRect, gaps)
        assertEquals("@王小明 你看下这个", line.text)
        // 字框不准时，@提及的框也不能越过空格盖到"你"（"你"从 x=194 开始）
        val f = DetectionPipeline.textFindings(listOf(line)).single { it.kind == FindingKind.MENTION }
        assertTrue(f.rect.maxX <= gaps[0] && f.rect.maxX > 170f, "${f.rect}")
    }

    @Test fun 气泡边缘认成的竖线和命中一起盖住() {
        // ML Kit 把气泡左边缘认成 "|"，"@" 的真实位置落在 "|" 的框里
        val symbols = "|@王小明".mapIndexed { i, c -> c.toString() to Rect(i * 30f, 0f, 28f, 32f) }
        val line = RecognizedLine.fromSymbols(symbols, 0.9f, Rect(0f, 0f, 150f, 32f))
        val f = DetectionPipeline.textFindings(listOf(line)).single { it.kind == FindingKind.MENTION }
        assertEquals("@王小明", f.text)
        assertTrue(f.rect.minX <= 0f, "${f.rect}")
    }

    @Test fun 单独一行的标签把右边的值盖住() {
        val label = line("收货人", 40f, 100f, 120f)
        val value = line("张三", 400f, 102f, 80f)
        val other = line("配送时间", 40f, 200f, 160f)
        val found = DetectionPipeline.textFindings(listOf(label, value, other))
        assertEquals(listOf(value.rect), found.filter { it.kind == FindingKind.KEYWORD_VALUE }.map { it.rect })
    }

    @Test fun 折行的邮箱两半都盖住() {
        val a = line("请发到 zhang.san@exam", 40f, 100f, 420f)
        val b = line("ple.com 谢谢", 40f, 145f, 220f)
        val found = DetectionPipeline.crossLineFindings(listOf(a, b)).filter { it.kind == FindingKind.EMAIL }
        assertEquals(2, found.size)
        assertEquals(setOf(100f, 145f), found.map { it.rect.minY }.toSet())
    }

    @Test fun 头像里的人脸不重复框() {
        val small = chatScreenshot()
        val avatar = Rect(12f, 100f, 40f, 40f)
        val vision = VisionResult(faces = listOf(Rect(16f, 104f, 30f, 30f) to 0.9f))
        val result = DetectionPipeline.analyze(vision, small, 1f, small.width, small.height)
        assertTrue(result.findings.any { it.kind == FindingKind.CHAT_AVATAR && it.rect.iou(avatar) > 0.6f })
        assertTrue(result.findings.none { it.kind == FindingKind.FACE })
    }
}

/** 400 宽的仿群聊截图：左右两列头像 + 紧挨着的气泡；左侧头像右边、气泡上方留出昵称的位置 */
internal fun chatScreenshot(): RgbaImage {
    val bg = argb(237, 237, 237)
    return makeImage(400, 800, bg) {
        for ((i, y) in listOf(100, 220, 340, 460, 580).withIndex()) {
            if (i % 2 == 0) {
                fillRect(12, y, 40, 40, argb(60 + i * 20, 120, 200))     // 左头像
                fillRect(58, y + 20, 200, 48, argb(255, 255, 255))       // 白气泡
            } else {
                fillRect(348, y, 40, 40, argb(200, 90 + i * 10, 60))     // 右头像
                fillRect(140, y, 202, 40, argb(149, 236, 105))           // 绿气泡
            }
        }
    }
}

class ChatLayoutTest {
    @Test fun 左右两列头像都能找到() {
        val img = chatScreenshot()
        val result = DetectionPipeline.analyze(VisionResult(), img, 1f, img.width, img.height)
        val avatars = result.findings.filter { it.kind == FindingKind.CHAT_AVATAR }
        val truth = listOf(100, 340, 580).map { Rect(12f, it.toFloat(), 40f, 40f) } +
            listOf(220, 460).map { Rect(348f, it.toFloat(), 40f, 40f) }
        for (t in truth) assertNotNull(avatars.find { it.rect.iou(t) >= 0.6f && it.isEnabled }, "漏检 $t，实际：${avatars.map { it.rect }}")
        assertEquals(truth.size, avatars.size)
    }

    @Test fun 昵称和标题() {
        val img = chatScreenshot()
        val lines = listOf(
            RecognizedLine("项目讨论群(5)", 0.9f, Rect(140f, 40f, 120f, 20f)),
            RecognizedLine("张三", 0.9f, Rect(60f, 101f, 40f, 14f)),      // 头像右侧、气泡上方的小字
            RecognizedLine("李四", 0.9f, Rect(60f, 341f, 40f, 14f)),
            RecognizedLine("好的，明天见", 0.9f, Rect(70f, 126f, 120f, 18f)),   // 气泡里的正文不是昵称
        )
        val result = DetectionPipeline.analyze(VisionResult(lines = lines), img, 1f, img.width, img.height)
        assertEquals(setOf("张三", "李四"), result.findings.filter { it.kind == FindingKind.CHAT_NICKNAME }.mapNotNull { it.text }.toSet())
        assertEquals("项目讨论群(5)", result.findings.single { it.kind == FindingKind.CHAT_TITLE }.text)
    }

    @Test fun 昵称末尾OCR认不出的表情也盖住() {
        // "张三🐟"：OCR 行框只到"三"，表情是紧跟着的一小块彩色像素
        val img = chatScreenshot().apply { fillRect(103, 102, 12, 12, argb(40, 160, 230)) }
        val lines = listOf(RecognizedLine("张三", 0.9f, Rect(60f, 101f, 40f, 14f)))
        val result = DetectionPipeline.analyze(VisionResult(lines = lines), img, 1f, img.width, img.height)
        val nick = result.findings.single { it.kind == FindingKind.CHAT_NICKNAME }
        assertTrue(nick.rect.maxX >= 115f, "${nick.rect}")
        assertTrue(nick.rect.maxX < 130f, "不能一路延伸到别处：${nick.rect}")
    }

    @Test fun 普通照片不做聊天布局分析() {
        // 渐变图：没有统一的页面背景色，不应该冒出头像 / 昵称
        val img = RgbaImage(400, 800)
        for (y in 0 until 800) for (x in 0 until 400) img[x, y] = argb(255 * x / 400, 100, 255 * y / 800)
        val result = DetectionPipeline.analyze(VisionResult(), img, 1f, 400, 800)
        assertTrue(result.findings.none { it.kind in setOf(FindingKind.CHAT_AVATAR, FindingKind.CHAT_NICKNAME, FindingKind.CHAT_TITLE) })
    }
}
