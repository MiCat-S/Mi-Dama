// 几何：原图像素坐标，左上角为原点（与 Android Bitmap / Compose 一致）
package com.example.redact.core

import kotlin.math.max
import kotlin.math.min

data class Rect(val x: Float, val y: Float, val width: Float, val height: Float) {
    val minX get() = x
    val minY get() = y
    val maxX get() = x + width
    val maxY get() = y + height
    val midX get() = x + width / 2
    val midY get() = y + height / 2

    val isEmpty get() = width <= 0f || height <= 0f
    val area get() = if (isEmpty) 0f else width * height

    fun intersection(other: Rect): Rect {
        val x0 = max(minX, other.minX)
        val y0 = max(minY, other.minY)
        val x1 = min(maxX, other.maxX)
        val y1 = min(maxY, other.maxY)
        return if (x1 > x0 && y1 > y0) Rect(x0, y0, x1 - x0, y1 - y0) else EMPTY
    }

    fun intersects(other: Rect) = !intersection(other).isEmpty

    fun union(other: Rect): Rect {
        if (isEmpty) return other
        if (other.isEmpty) return this
        return fromLTRB(min(minX, other.minX), min(minY, other.minY), max(maxX, other.maxX), max(maxY, other.maxY))
    }

    /** 正值向内缩，负值向外扩 */
    fun inset(dx: Float, dy: Float) = Rect(x + dx, y + dy, width - 2 * dx, height - 2 * dy)

    fun offset(dx: Float, dy: Float) = Rect(x + dx, y + dy, width, height)

    fun scaled(s: Float) = Rect(x * s, y * s, width * s, height * s)

    fun contains(px: Float, py: Float) = px >= minX && px < maxX && py >= minY && py < maxY

    fun contains(other: Rect) = other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY

    /** 交并比 */
    fun iou(other: Rect): Float {
        val inter = intersection(other).area
        val union = area + other.area - inter
        return if (union > 0) inter / union else 0f
    }

    companion object {
        val EMPTY = Rect(0f, 0f, 0f, 0f)
        fun fromLTRB(l: Float, t: Float, r: Float, b: Float) = Rect(l, t, r - l, b - t)
    }
}

/** 字符下标的半开区间 [start, end)（UTF-16 下标，与 String / Regex 一致） */
data class Span(val start: Int, val end: Int) {
    val length get() = end - start
}
