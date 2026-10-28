// 记住用户上次的选择：打码效果和颜色、导出选项、哪些原图已经打过码。改动即持久化
package com.example.redact.data

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.example.redact.core.MaskStyle
import com.example.redact.core.render.ExportFormat
import com.example.redact.core.render.ExportSize
import com.example.redact.core.render.HexColor
import com.example.redact.core.render.WatermarkSpec
import org.json.JSONObject

object Settings {
    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        if (!::prefs.isInitialized) {
            prefs = context.applicationContext.getSharedPreferences("settings", Context.MODE_PRIVATE)
            export = ExportSettings(prefs)
        }
    }

    /** null = 自动（按类别选默认效果） */
    var style: MaskStyle?
        get() = prefs.getString("maskStyle", null)?.let { name -> MaskStyle.entries.find { it.name == name } }
        set(v) = prefs.edit().putString("maskStyle", v?.name ?: "auto").apply()

    /** 色块、杂讯色块的颜色（ARGB） */
    var fillColor: Int
        get() = HexColor.parse(prefs.getString("maskColor", null) ?: PALETTE[0].second)
        set(v) = prefs.edit().putString("maskColor", HexColor.format(v)).apply()

    var openLatestOnLaunch: Boolean
        get() = prefs.getBoolean("openLatestOnLaunch", true)
        set(v) = prefs.edit().putBoolean("openLatestOnLaunch", v).apply()

    /** 上次自动打开的图片：从后台回来时只有出现了新图片才会再自动打开 */
    var lastAutoOpened: String
        get() = prefs.getString("lastAutoOpened", "") ?: ""
        set(v) = prefs.edit().putString("lastAutoOpened", v).apply()

    /** 是否已经弹过相册权限请求（区分"还没问过"和"被拒绝了"） */
    var askedPhotoPermission: Boolean
        get() = prefs.getBoolean("askedPhotoPermission", false)
        set(v) = prefs.edit().putBoolean("askedPhotoPermission", v).apply()

    /** 已经保存过打码版本的原图（MediaStore id），打开 App 时不再自动进入它们 */
    val processed: Set<Long>
        get() = prefs.getString("processedAssets", "").orEmpty().split(',').mapNotNull { it.toLongOrNull() }.toSet()

    fun markProcessed(ids: List<Long>) {
        if (ids.isEmpty()) return
        val list = prefs.getString("processedAssets", "").orEmpty().split(',').mapNotNull { it.toLongOrNull() }
            .filter { it !in ids } + ids
        prefs.edit().putString("processedAssets", list.takeLast(500).joinToString(",")).apply()
    }

    lateinit var export: ExportSettings
        private set

    val PALETTE = listOf(
        "深灰" to "#1C1C1E", "白" to "#FFFFFF", "灰" to "#8E8E93", "绿" to "#34C759",
        "蓝" to "#007AFF", "红" to "#FF3B30", "黄" to "#FFCC00", "紫" to "#AF52DE",
    )
}

/** 导出选项：对所有图片生效（批量保存时行为一致）；Compose 状态，界面直接读写 */
class ExportSettings internal constructor(private val prefs: SharedPreferences) {
    enum class FormatChoice(val label: String) {
        AUTO("自动（截图 PNG，照片 JPEG）"), PNG("PNG"), JPEG("JPEG"), WEBP("WebP")
    }

    enum class SizeChoice(val label: String, val exportSize: ExportSize) {
        ORIGINAL("原尺寸", ExportSize.Original),
        SIDE_2560("长边 2560", ExportSize.MaxSide(2560)),
        SIDE_1920("长边 1920", ExportSize.MaxSide(1920)),
        SIDE_1280("长边 1280", ExportSize.MaxSide(1280)),
    }

    var format by mutableStateOf(enumOr(prefs.getString("export.format", null), FormatChoice.AUTO))
    var size by mutableStateOf(enumOr(prefs.getString("export.size", null), SizeChoice.ORIGINAL))
    var watermarkEnabled by mutableStateOf(prefs.getBoolean("export.watermarkEnabled", false))
    var watermark by mutableStateOf(decodeWatermark(prefs.getString("export.watermark", null)))

    /** 保存打码图后把相册里的原图移到回收站（默认关闭） */
    var deleteOriginal by mutableStateOf(prefs.getBoolean("export.deleteOriginal", false))

    /** 写回磁盘；界面在改动后调用 */
    fun persist() {
        prefs.edit()
            .putString("export.format", format.name)
            .putString("export.size", size.name)
            .putBoolean("export.watermarkEnabled", watermarkEnabled)
            .putString("export.watermark", encodeWatermark(watermark))
            .putBoolean("export.deleteOriginal", deleteOriginal)
            .apply()
    }

    fun exportFormat(isScreenshot: Boolean) = when (format) {
        FormatChoice.AUTO -> if (isScreenshot) ExportFormat.PNG else ExportFormat.JPEG
        FormatChoice.PNG -> ExportFormat.PNG
        FormatChoice.JPEG -> ExportFormat.JPEG
        FormatChoice.WEBP -> ExportFormat.WEBP
    }

    /** 实际要画的水印；关闭或没填文字时为 null */
    val activeWatermark get() = if (watermarkEnabled && !watermark.isEmpty) watermark else null

    private companion object {
        inline fun <reified E : Enum<E>> enumOr(name: String?, fallback: E) =
            enumValues<E>().find { it.name == name } ?: fallback

        fun encodeWatermark(w: WatermarkSpec) = JSONObject()
            .put("text", w.text).put("fontScale", w.fontScale.toDouble()).put("colorHex", w.colorHex)
            .put("opacity", w.opacity.toDouble()).put("angleDegrees", w.angleDegrees.toDouble()).put("spacing", w.spacing.toDouble())
            .toString()

        fun decodeWatermark(s: String?): WatermarkSpec {
            val d = WatermarkSpec()
            val o = runCatching { JSONObject(s ?: return d) }.getOrNull() ?: return d
            return WatermarkSpec(
                text = o.optString("text", d.text),
                fontScale = o.optDouble("fontScale", d.fontScale.toDouble()).toFloat(),
                colorHex = o.optString("colorHex", d.colorHex),
                opacity = o.optDouble("opacity", d.opacity.toDouble()).toFloat(),
                angleDegrees = o.optDouble("angleDegrees", d.angleDegrees.toDouble()).toFloat(),
                spacing = o.optDouble("spacing", d.spacing.toDouble()).toFloat(),
            )
        }
    }
}
