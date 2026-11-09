package com.example.redact.core

import com.example.redact.core.render.*
import com.example.redact.core.detect.TextLine
import kotlin.test.*

class CompositionTest {
    private fun layout(axis: MergeLayout.Axis, gap: MergeLayout.Gap = MergeLayout.Gap.NONE, order: List<Int> = listOf(0, 1)) = MergeLayout(axis, gap, order = order)
    @Test fun verticalOnlyDownscales() {
        val c = Composition(listOf(ImageSize(1000, 2000), ImageSize(500, 800)), layout(MergeLayout.Axis.VERTICAL))
        assertEquals(ImageSize(500, 1800), c.canvasSize)
        assertEquals(listOf(Rect(0f, 0f, 500f, 1000f), Rect(0f, 1000f, 500f, 800f)), c.frames)
    }
    @Test fun horizontalGapAndOrder() {
        val sizes = List(2) { ImageSize(1290, 2796) }
        val c = Composition(sizes, layout(MergeLayout.Axis.HORIZONTAL, MergeLayout.Gap.THIN, listOf(1, 0)))
        assertEquals(ImageSize(2606, 2796), c.canvasSize)
        assertEquals(0f, c.frames[1].x)
        assertEquals(1316f, c.frames[0].x)
        assertEquals(listOf(0, 1), Composition(sizes, layout(MergeLayout.Axis.VERTICAL, order = listOf(0, 0))).layout.order)
    }
    @Test fun capsLongImages() {
        val c = Composition(List(2) { ImageSize(1290, 20000) }, layout(MergeLayout.Axis.VERTICAL))
        assertTrue(c.canvasSize.width.toLong() * c.canvasSize.height <= 24_000_000)
        assertTrue(c.canvasSize.width > 800)
        assertEquals(c.frames[0].maxY, c.frames[1].y)
        assertEquals(20000f / 1290, c.frames[0].height / c.frames[0].width, 0.01f)
    }
    @Test fun choosesAxis() {
        val portrait = ImageSize(1290, 2796); val landscape = ImageSize(4032, 3024)
        assertEquals(MergeLayout.Axis.HORIZONTAL, MergeLayout.defaultAxis(listOf(portrait, portrait)))
        assertEquals(MergeLayout.Axis.VERTICAL, MergeLayout.defaultAxis(listOf(portrait, landscape)))
        assertEquals(MergeLayout.Axis.VERTICAL, MergeLayout.defaultAxis(listOf(landscape, landscape)))
    }
    @Test fun coordinatesRoundTrip() {
        val c = Composition(listOf(ImageSize(1000, 2000), ImageSize(500, 800)), layout(MergeLayout.Axis.VERTICAL, MergeLayout.Gap.THICK, listOf(1, 0)))
        val r = Rect(100f, 300f, 200f, 50f)
        val canvas = c.toCanvas(r, 0)
        assertEquals(Rect(50f, c.frames[0].y + 150f, 100f, 25f), canvas)
        assertEquals(listOf(0 to r), c.toParts(canvas))
    }
    @Test fun preservesEditsAndText() {
        val c = Composition(List(2) { ImageSize(100, 100) }, layout(MergeLayout.Axis.HORIZONTAL))
        val off = Finding(FindingKind.PHONE, Rect(10f, 10f, 20f, 5f), 0.9f, isEnabled = false)
        val styled = Finding(FindingKind.FACE, Rect(0f, 0f, 50f, 50f), 0.9f, style = MaskStyle.SOLID)
        val merged = c.findings(listOf(listOf(off), listOf(styled)))
        assertEquals(off, merged[0])
        assertEquals(styled.copy(rect = Rect(100f, 0f, 50f, 50f)), merged[1])
        assertEquals(Rect(100f, 0f, 50f, 50f), c.textLines(listOf(emptyList(), listOf(TextLine(styled.rect, "text")))).single().rect)
    }
    @Test fun seamSplitsAndGapDrops() {
        val sizes = List(2) { ImageSize(100, 200) }
        val a = Composition(sizes, layout(MergeLayout.Axis.VERTICAL))
        val b = Composition(sizes, layout(MergeLayout.Axis.HORIZONTAL, MergeLayout.Gap.THIN))
        val f = Finding(FindingKind.MANUAL, Rect(20f, 180f, 60f, 40f), 1f, style = MaskStyle.BLUR)
        val moved = a.remap(listOf(f), b)
        assertEquals(2, moved.size)
        assertEquals(f.id, moved[0].id)
        assertNotEquals(f.id, moved[1].id)
        assertEquals(Rect(20f, 180f, 60f, 20f), moved[0].rect)
        assertEquals(Rect(b.frames[1].x + 20, 0f, 60f, 20f), moved[1].rect)
        assertTrue(moved.all { it.style == MaskStyle.BLUR && it.isEnabled })
        val back = b.remap(moved, a)
        assertEquals(f.rect, back[0].rect.union(back[1].rect))
        val gap = Finding(FindingKind.MANUAL, Rect(101f, 10f, 1f, 50f), 1f)
        assertTrue(b.remap(listOf(gap), a).isEmpty())
        val history = EditHistory<Pair<List<Finding>, MergeLayout>>()
        val before = listOf(f) to a.layout; val after = moved to b.layout
        history.record(before, after)
        assertEquals(before, history.undo(after)); assertEquals(after, history.redo(before))
    }
    @Test fun pixelsAndMappedRedaction() {
        val c = Composition(listOf(ImageSize(100, 200), ImageSize(50, 100)), MergeLayout(MergeLayout.Axis.VERTICAL, MergeLayout.Gap.THICK, MergeLayout.Background.BLACK))
        val colors = listOf(argb(255, 0, 0), argb(0, 0, 255))
        val out = c.compose { i -> RgbaImage(c.partSizes[i].width, c.partSizes[i].height).also { it.pixels.fill(colors[i]) } }
        assertEquals(colors[0], out[0, 99]); assertEquals(argb(0, 0, 0), out[0, 100])
        assertEquals(colors[1], out[0, c.frames[1].y.toInt()])
        val f = Finding(FindingKind.PHONE, Rect(10f, 10f, 20f, 20f), 1f, style = MaskStyle.SOLID)
        val redacted = Redactor(argb(0, 255, 0)).render(out, c.findings(listOf(emptyList(), listOf(f))))
        assertEquals(argb(0, 255, 0), redacted[15, c.frames[1].y.toInt() + 15])
        assertEquals(colors[1], redacted[0, c.frames[1].y.toInt()])
    }
}
