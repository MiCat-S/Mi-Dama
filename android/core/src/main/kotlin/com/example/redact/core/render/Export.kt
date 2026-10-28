// 导出相关的纯逻辑：尺寸、格式、水印参数、截图 / 照片判断、效果小样
package com.example.redact.core.render

import com.example.redact.core.Finding
import com.example.redact.core.FindingKind
import com.example.redact.core.MaskStyle
import com.example.redact.core.Rect
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

enum class ExportFormat(val extension: String, val mimeType: String) {
    /** 截图用 PNG，文字边缘不糊 */
    PNG("png", "image/png"),

    /** 兼容性最好（部分聊天软件、网页不认 WebP） */
    JPEG("jpg", "image/jpeg"),

    /** 体积比 JPEG 小 */
    WEBP("webp", "image/webp"),
}

/** 导出尺寸。缩放只发生在打码之后，所以缩小不会让打码变弱 */
sealed interface ExportSize {
    data object Original : ExportSize

    /** 长边不超过该像素值（不会放大） */
    data class MaxSide(val side: Int) : ExportSize

    /** 再加一个长边上限（预览用：不需要比屏幕显示更大的图） */
    fun capped(side: Int): ExportSize = when (this) {
        Original -> MaxSide(side)
        is MaxSide -> MaxSide(min(this.side, side))
    }

    /** 输出宽高 */
    fun apply(width: Int, height: Int): Pair<Int, Int> {
        if (this !is MaxSide) return width to height
        val longest = max(width, height)
        if (side <= 0 || longest <= side) return width to height
        val scale = side.toFloat() / longest
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }
}

/** 全图平铺文字水印（证件照常用："仅供办理 XX 使用"） */
data class WatermarkSpec(
    val text: String = "",
    /** 字号 = 图片宽度 × fontScale */
    val fontScale: Float = 0.045f,
    val colorHex: String = "#000000",
    /** 0–1 */
    val opacity: Float = 0.25f,
    /** 负值向右上倾斜 */
    val angleDegrees: Float = -30f,
    /** 行、列之间的空隙 = 字号 × spacing */
    val spacing: Float = 2.0f,
) {
    val isEmpty get() = text.isBlank()
}

/** 判断一张图是截图还是相机照片（决定"自动"导出格式：截图用无损 PNG，照片用 JPEG） */
object ImageKind {
    private val pngMagic = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47)

    /**
     * 相册里的截图常被转码成 JPEG 分享，只看容器格式不可靠。
     * 相机拍的照片 EXIF 里一定有快门 / 光圈，截图没有；部分系统截图还会在 UserComment 写 "Screenshot"
     */
    fun isLikelyScreenshot(header: ByteArray, userComment: String?, hasCameraExposure: Boolean): Boolean {
        if (header.size >= 4 && header.copyOf(4).contentEquals(pngMagic)) return true
        if (userComment?.contains("screenshot", ignoreCase = true) == true) return true
        return !hasCameraExposure
    }
}

/** 效果小样：一块彩色格纹被该效果盖住后的样子（菜单图标、底部按钮用），都用真实渲染器生成 */
object EffectPreview {
    private val colors = intArrayOf(0x007AFF, 0xFF2D55, 0xFFCC00, 0x34C759, 0xAF52DE, 0xFF9500)

    fun swatch(style: MaskStyle?, fillColor: Int, side: Int): RgbaImage {
        val sample = RgbaImage(side, side)
        val cell = max(1, side / 4)
        for (y in 0 until side) {
            for (x in 0 until side) {
                val r = min(3, y / cell)
                val c = min(3, x / cell)
                sample[x, y] = colors[(r * 3 + c) % colors.size] or (0xFF shl 24)
            }
        }
        // "自动"对图片区域默认用像素化，这里按头像类别演示；框比图大，整块都被盖住
        val finding = Finding(FindingKind.CHAT_AVATAR, Rect(0f, 0f, side * 3f, side * 3f), 1f)
        return Redactor(fillColor).render(sample, listOf(finding), style)
    }
}
