// 编辑画布：直接显示打码后的效果（所见即所得）
//  · 点一下打码区域 → 取消这一处（露出原图，留一圈虚线方便再点回来）；再点 → 恢复
//  · 长按 → 单独设置这一处的效果 / 删除手动框
//  · 文字工具：点一下文字行，盖住整行；马克笔工具：拖出一个框；取色器：点一下吸取颜色
//  · 双指缩放、放大后单指拖动、双击在原大小和放大之间切换
package com.example.redact.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.redact.core.Finding
import com.example.redact.core.FindingKind
import com.example.redact.core.MaskStyle
import com.example.redact.core.Rect
import com.example.redact.data.RedactItem
import com.example.redact.data.TiledImage
import kotlin.math.max
import kotlin.math.min

/** 当前的编辑工具；null = 普通模式（点区域开关） */
enum class EditTool { TEXT, MARKER, EYEDROPPER }

@Composable
fun ReviewCanvas(
    item: RedactItem,
    /** 打码后的渲染结果；还没渲染好时显示原图 */
    rendered: TiledImage?,
    tool: EditTool?,
    /** 识别中不允许编辑 */
    editable: Boolean,
    /** 每次编辑后调用（触感反馈） */
    onEdit: () -> Unit,
    /** 取色器点中的图片坐标 */
    onPickColor: (Float, Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val display = item.display
    val coords = item.size ?: display?.let { IntSize(it.width, it.height) }
    if (display == null || coords == null) {
        Box(modifier)
        return
    }
    val density = LocalDensity.current
    val margin = with(density) { 16.dp.toPx() }
    var viewport by remember { mutableStateOf(IntSize.Zero) }
    var zoom by remember(item.id) { mutableFloatStateOf(1f) }
    var offset by remember(item.id) { mutableStateOf(Offset.Zero) }
    var markerRect by remember { mutableStateOf<androidx.compose.ui.geometry.Rect?>(null) }
    var menu by remember { mutableStateOf<Pair<String, Offset>?>(null) }
    val haptic = LocalHapticFeedback.current
    val measurer = rememberTextMeasurer()

    val imgW = coords.width.toFloat()
    val imgH = coords.height.toFloat()
    val fit = if (viewport.width > 0) {
        min((viewport.width - margin * 2) / imgW, (viewport.height - margin * 2) / imgH).coerceAtLeast(0.0001f)
    } else 1f
    // 长截图 1x 时很小：最大倍数至少能放大到"宽度铺满"再放大 3 倍
    val maxZoom = max(6f, (viewport.width - margin * 2) / (imgW * fit) * 3)

    fun clamp(o: Offset, z: Float): Offset {
        val w = imgW * fit * z
        val h = imgH * fit * z
        val mx = max(0f, (w - viewport.width) / 2 + margin)
        val my = max(0f, (h - viewport.height) / 2 + margin)
        return Offset(o.x.coerceIn(-mx, mx), o.y.coerceIn(-my, my))
    }

    fun topLeft(z: Float = zoom, o: Offset = offset) =
        Offset(viewport.width / 2f - imgW * fit * z / 2 + o.x, viewport.height / 2f - imgH * fit * z / 2 + o.y)

    fun toImage(p: Offset): Offset {
        val tl = topLeft()
        return Offset((p.x - tl.x) / (fit * zoom), (p.y - tl.y) / (fit * zoom))
    }

    /** 以 [center]（屏幕坐标）为中心缩放，保持该点下的图片内容不动 */
    fun zoomAround(center: Offset, newZoom: Float) {
        val z = newZoom.coerceIn(1f, maxZoom)
        val c = center - Offset(viewport.width / 2f, viewport.height / 2f)
        offset = clamp(c - (c - offset) * (z / zoom), z)
        zoom = z
    }

    /** 点中的区域：取面积最小的（小框叠在大框上时能点到小框）；太小的框至少按 8dp 算 */
    fun hit(p: Offset): Finding? {
        val ip = toImage(p)
        val minSide = with(density) { 8.dp.toPx() } / (fit * zoom)
        return item.findings.filter { f ->
            val r = f.rect
            val padX = max(0f, (minSide - r.width) / 2)
            val padY = max(0f, (minSide - r.height) / 2)
            r.inset(-padX, -padY).contains(ip.x, ip.y)
        }.minByOrNull { it.rect.area }
    }

    val currentTool by rememberUpdatedState(tool)
    val canEdit by rememberUpdatedState(editable)
    val edited by rememberUpdatedState(onEdit)
    val pickColor by rememberUpdatedState(onPickColor)

    Box(
        modifier
            .onSizeChanged { viewport = it }
            .pointerInput(item.id, fit) {
                // 双指缩放 / 放大后拖动 / 马克笔画框（单指）
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val markerStart = if (currentTool == EditTool.MARKER && canEdit) down.position else null
                    var multi = false
                    var dragging = false
                    var moved = Offset.Zero
                    while (true) {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        if (pressed.isEmpty()) break
                        if (pressed.size >= 2) {
                            multi = true
                            markerRect = null
                            val centroid = event.calculateCentroid(useCurrent = true)
                            zoomAround(centroid, zoom * event.calculateZoom())
                            offset = clamp(offset + event.calculatePan(), zoom)
                            event.changes.forEach { it.consume() }
                        } else if (!multi) {
                            val ch = pressed[0]
                            moved += ch.positionChange()
                            if (!dragging && moved.getDistance() > viewConfiguration.touchSlop) dragging = true
                            if (!dragging) continue
                            if (markerStart != null) {
                                val p = ch.position
                                markerRect = androidx.compose.ui.geometry.Rect(
                                    min(markerStart.x, p.x), min(markerStart.y, p.y), max(markerStart.x, p.x), max(markerStart.y, p.y),
                                )
                                ch.consume()
                            } else if (zoom > 1.01f) {
                                offset = clamp(offset + ch.positionChange(), zoom)
                                ch.consume()
                            }
                        }
                    }
                    val r = markerRect
                    if (markerStart != null && !multi && r != null && r.width > 6 && r.height > 6) {
                        val a = toImage(r.topLeft)
                        val b = toImage(r.bottomRight)
                        val imageRect = Rect.fromLTRB(a.x, a.y, b.x, b.y)
                            .intersection(Rect(0f, 0f, imgW, imgH))
                        if (!imageRect.isEmpty) {
                            item.addFinding(Finding(FindingKind.MANUAL, imageRect, 1f))
                            edited()
                        }
                    }
                    markerRect = null
                }
            }
            .pointerInput(item.id, fit) {
                detectTapGestures(
                    onDoubleTap = { p ->
                        // 双击：已放大则还原，否则以点击处为中心放大到 2.5 倍
                        if (zoom > 1.01f) {
                            zoom = 1f
                            offset = Offset.Zero
                        } else {
                            zoomAround(p, 2.5f)
                        }
                    },
                    onTap = { p ->
                        if (!canEdit) return@detectTapGestures
                        val ip = toImage(p)
                        when (currentTool) {
                            EditTool.TEXT -> if (item.toggleTextLine(ip.x, ip.y)) edited()
                            EditTool.EYEDROPPER -> if (ip.x in 0f..imgW && ip.y in 0f..imgH) pickColor(ip.x, ip.y)
                            EditTool.MARKER -> Unit
                            null -> hit(p)?.let { f ->
                                item.updateFinding(f.id) { it.copy(isEnabled = !it.isEnabled) }
                                edited()
                            }
                        }
                    },
                    onLongPress = { p ->
                        if (!canEdit || currentTool != null) return@detectTapGestures
                        hit(p)?.let {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            menu = it.id to p
                        }
                    },
                )
            },
    ) {
        val image = rendered ?: display
        val cardColor = androidx.compose.material3.MaterialTheme.colorScheme.surface
        Canvas(Modifier.fillMaxSize()) {
            if (viewport.width == 0) return@Canvas
            val tl = topLeft()
            val s = fit * zoom
            val w = imgW * s
            val h = imgH * s
            val corner = CornerRadius(10.dp.toPx())
            // 卡片阴影 + 底色
            drawRoundRect(Color.Black.copy(alpha = 0.12f), tl + Offset(0f, 6.dp.toPx()), Size(w, h), corner)
            drawRoundRect(cardColor, tl, Size(w, h), corner)
            val clip = Path().apply {
                addRoundRect(androidx.compose.ui.geometry.RoundRect(tl.x, tl.y, tl.x + w, tl.y + h, corner))
            }
            clipPath(clip) {
                // 显示图和坐标系的像素数可能不同（大图显示时缩小过）：按比例铺满同一块区域
                val k = h / image.height
                for ((y, tile) in image.tiles) {
                    val top = tl.y + y * k
                    // 只画屏幕内的条带
                    if (top > size.height || top + tile.height * k < 0) continue
                    drawImage(
                        tile, dstOffset = IntOffset(tl.x.toInt(), top.toInt()),
                        dstSize = IntSize((tl.x + w).toInt() - tl.x.toInt(), (top + tile.height * k).toInt() - top.toInt()),
                        filterQuality = if (s * imgW / image.width > 1.5f) FilterQuality.None else FilterQuality.Medium,
                    )
                }
            }
            if (item.size == null) return@Canvas
            // 没在打码的区域画一圈虚线，提示"这里识别到了，点一下可以打码"；打码中的区域效果已经在图上
            val dash = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))
            for (f in item.findings) {
                val r = f.rect
                val o = Offset(tl.x + r.x * s, tl.y + r.y * s)
                val sz = Size(r.width * s, r.height * s)
                val tint = f.kind.tint
                if (!f.isEnabled) {
                    drawRect(tint.copy(alpha = 0.08f), o, sz)
                    drawRect(tint, o, sz, style = Stroke(1.5.dp.toPx(), pathEffect = dash))
                } else if (f.style != null) {
                    // 单独指定了效果：角标贴在框的上沿外侧
                    val label = measurer.measure(f.style!!.label, TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = Color.White))
                    val bw = label.size.width + 6.dp.toPx()
                    val bh = label.size.height.toFloat()
                    val bo = Offset(o.x + sz.width - bw, o.y - bh)
                    drawRoundRect(tint, bo, Size(bw, bh), CornerRadius(3.dp.toPx()))
                    drawText(label, topLeft = bo + Offset(3.dp.toPx(), 0f))
                }
            }
            markerRect?.let { drawRect(Color(0xFFFFCC00), it.topLeft, it.size, style = Stroke(2.dp.toPx())) }
        }

        // 长按菜单：单独开关、单独换效果、删除手动框
        val target = menu?.let { (id, _) -> item.findings.find { it.id == id } }
        if (target != null) {
            val at = menu!!.second
            Box(Modifier.offset { IntOffset(at.x.toInt(), at.y.toInt()) }) {
                FindingMenu(target, item, onDismiss = { menu = null }, onEdit = onEdit)
            }
        }
    }
}

@Composable
private fun FindingMenu(finding: Finding, item: RedactItem, onDismiss: () -> Unit, onEdit: () -> Unit) {
    DropdownMenu(expanded = true, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = { Text(if (finding.isEnabled) "这一处不打码" else "这一处打码") },
            leadingIcon = { Icon(if (finding.isEnabled) Icons.Outlined.Visibility else Icons.Outlined.VisibilityOff, null) },
            onClick = {
                item.updateFinding(finding.id) { it.copy(isEnabled = !it.isEnabled) }
                onEdit()
                onDismiss()
            },
        )
        HorizontalDivider()
        Text(
            "这一处的效果", style = androidx.compose.material3.MaterialTheme.typography.labelMedium,
            modifier = Modifier.offset(x = 16.dp), color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
        )
        val choices: List<Pair<MaskStyle?, String>> = listOf(null to "跟随全局（${item.styleOverride?.label ?: "自动"}）") +
            MaskStyle.entries.map { it to it.label }
        for ((style, label) in choices) {
            DropdownMenuItem(
                text = { Text(label) },
                leadingIcon = { if (finding.style == style) Icon(Icons.Filled.Check, null) else Box(Modifier) },
                onClick = {
                    item.updateFinding(finding.id) { it.copy(style = style, isEnabled = true) }
                    onEdit()
                    onDismiss()
                },
            )
        }
        if (finding.kind == FindingKind.MANUAL) {
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("删除这个框", color = androidx.compose.material3.MaterialTheme.colorScheme.error) },
                leadingIcon = { Icon(Icons.Outlined.Delete, null, tint = androidx.compose.material3.MaterialTheme.colorScheme.error) },
                onClick = {
                    item.removeFinding(finding.id)
                    onEdit()
                    onDismiss()
                },
            )
        }
    }
}

/** 点阵画板背景 */
@Composable
fun DotGridBackground(modifier: Modifier = Modifier) {
    val dot = androidx.compose.material3.MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)
    val bg = androidx.compose.material3.MaterialTheme.colorScheme.surfaceContainerLow
    Canvas(modifier) {
        drawRect(bg)
        val step = 18.dp.toPx()
        val r = 1.dp.toPx()
        var y = step / 2
        while (y < size.height) {
            var x = step / 2
            while (x < size.width) {
                drawCircle(dot, r, Offset(x, y))
                x += step
            }
            y += step
        }
    }
}
