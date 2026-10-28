// 图片读写：解码（按 EXIF 方向转正、限制像素数）、Bitmap ↔ RgbaImage、缩放、水印、无元数据编码、EXIF 读取
package com.example.redact.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.Typeface
import android.net.Uri
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.exifinterface.media.ExifInterface
import com.example.redact.core.render.ExportFormat
import com.example.redact.core.render.HexColor
import com.example.redact.core.render.RgbaImage
import com.example.redact.core.render.WatermarkSpec
import com.example.redact.core.render.blue
import com.example.redact.core.render.green
import com.example.redact.core.render.red
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

object Images {
    /**
     * 识别、打码用的原图最多这么多像素（约 2400 万，长截图 1080×20000 也在内）。
     * 超大照片按比例缩到这个像素数以内，避免两份整图缓冲撑爆内存
     */
    const val MAX_WORKING_PIXELS = 24_000_000

    /** 屏幕显示用图的像素上限 */
    const val MAX_DISPLAY_PIXELS = 12_000_000

    fun readBytes(context: Context, uri: Uri): ByteArray? =
        runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()

    /**
     * 解码为软件 ARGB_8888、sRGB 位图；ImageDecoder 会按 EXIF 方向转正（与 iOS 的 applyOrientationProperty 一致）
     * @param maxSide 长边上限（缩略图、显示用图）
     */
    fun decode(bytes: ByteArray, maxSide: Int? = null, maxPixels: Int = MAX_WORKING_PIXELS): Bitmap? = runCatching {
        val source = ImageDecoder.createSource(ByteBuffer.wrap(bytes))
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val w = info.size.width
            val h = info.size.height
            var scale = 1.0
            if (maxSide != null) scale = min(scale, maxSide.toDouble() / max(w, h))
            if (w.toLong() * h > maxPixels) scale = min(scale, sqrt(maxPixels.toDouble() / (w.toLong() * h)))
            if (scale < 1) decoder.setTargetSize(max(1, (w * scale).roundToInt()), max(1, (h * scale).roundToInt()))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
        }
        if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, false)
    }.getOrNull()

    fun toRgba(bitmap: Bitmap): RgbaImage {
        val img = RgbaImage(bitmap.width, bitmap.height)
        bitmap.getPixels(img.pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return img
    }

    fun toBitmap(img: RgbaImage): Bitmap = Bitmap.createBitmap(img.pixels, img.width, img.height, Bitmap.Config.ARGB_8888)

    /** 缩小到目标尺寸：先逐次减半再做最后一步，避免一次大比例双线性缩放产生锯齿 */
    fun scale(bitmap: Bitmap, width: Int, height: Int): Bitmap {
        if (bitmap.width == width && bitmap.height == height) return bitmap
        var b = bitmap
        while (b.width / 2 >= width && b.height / 2 >= height) {
            b = Bitmap.createScaledBitmap(b, b.width / 2, b.height / 2, true)
        }
        return Bitmap.createScaledBitmap(b, width, height, true)
    }

    /** 按像素上限缩小（显示用） */
    fun fitPixels(bitmap: Bitmap, maxPixels: Int): Bitmap {
        val px = bitmap.width.toLong() * bitmap.height
        if (px <= maxPixels) return bitmap
        val s = sqrt(maxPixels.toDouble() / px)
        return scale(bitmap, max(1, (bitmap.width * s).toInt()), max(1, (bitmap.height * s).toInt()))
    }

    /**
     * 全图平铺文字水印，画在输出尺寸上（字号、间距都按图片宽度换算）。
     * 绕中心旋转后按对角线长度铺满，保证四角也有水印；隔行错开半格
     */
    fun drawWatermark(bitmap: Bitmap, spec: WatermarkSpec): Bitmap {
        if (spec.isEmpty || spec.opacity <= 0) return bitmap
        val out = if (bitmap.isMutable) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, true)
        val w = out.width.toFloat()
        val h = out.height.toFloat()
        val fontSize = max(10f, w * spec.fontScale)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = fontSize
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            color = HexColor.parse(spec.colorHex)
            alpha = (spec.opacity.coerceIn(0f, 1f) * 255).roundToInt()
        }
        val lineWidth = paint.measureText(spec.text)
        val fm = paint.fontMetrics
        val gap = fontSize * max(0.2f, spec.spacing)
        val stepX = lineWidth + gap
        val stepY = (fm.descent - fm.ascent) + gap
        val diag = sqrt(w * w + h * h)
        val canvas = Canvas(out)
        canvas.translate(w / 2, h / 2)
        canvas.rotate(spec.angleDegrees)
        var row = 0
        var y = -diag / 2
        while (y < diag / 2) {
            var x = -diag / 2 - if (row % 2 == 1) stepX / 2 else 0f
            while (x < diag / 2) {
                canvas.drawText(spec.text, x, y - fm.ascent, paint)
                x += stepX
            }
            y += stepY
            row++
        }
        return out
    }

    /** 只写像素：Bitmap.compress 不会写入任何 EXIF / GPS / 设备信息 */
    fun encode(bitmap: Bitmap, format: ExportFormat): ByteArray {
        val out = ByteArrayOutputStream()
        val ok = when (format) {
            ExportFormat.PNG -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            ExportFormat.JPEG -> bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
            ExportFormat.WEBP -> bitmap.compress(Bitmap.CompressFormat.WEBP_LOSSY, 90, out)
        }
        check(ok) { "编码失败" }
        return out.toByteArray()
    }

    /** 长图切成若干横条：单张位图太高会超过 GPU 纹理上限而显示空白 */
    fun tiles(bitmap: Bitmap, tileHeight: Int = 2048): TiledImage {
        if (bitmap.height <= tileHeight) return TiledImage(bitmap.width, bitmap.height, listOf(0 to bitmap.asImageBitmap()))
        val list = (0 until bitmap.height step tileHeight).map { y ->
            y to Bitmap.createBitmap(bitmap, 0, y, bitmap.width, min(tileHeight, bitmap.height - y)).asImageBitmap()
        }
        return TiledImage(bitmap.width, bitmap.height, list)
    }

    /** 按图片坐标取一个像素的颜色（取色器） */
    fun pixelAt(img: RgbaImage, x: Float, y: Float): Int {
        val c = img[x.toInt().coerceIn(0, img.width - 1), y.toInt().coerceIn(0, img.height - 1)]
        return com.example.redact.core.render.argb(red(c), green(c), blue(c))
    }
}

/** 显示用图：可能被切成多条（见 Images.tiles） */
class TiledImage(val width: Int, val height: Int, val tiles: List<Pair<Int, ImageBitmap>>)

/** 原图元数据：让用户看到"如果不打码直接发出去，会泄露哪些信息"；导出时一律不写入 */
class PhotoMetadata(val groups: List<Pair<String, List<Pair<String, String>>>>) {
    val isEmpty get() = groups.isEmpty()

    /** 位置和设备信息才算敏感 */
    val hasSensitive get() = groups.any { it.first == "位置" || it.first == "设备" }

    companion object {
        private val tagGroups = listOf(
            "设备" to listOf(
                ExifInterface.TAG_MAKE to "厂商", ExifInterface.TAG_MODEL to "机型",
                ExifInterface.TAG_SOFTWARE to "系统版本", ExifInterface.TAG_DATETIME to "修改时间",
            ),
            "拍摄" to listOf(
                ExifInterface.TAG_DATETIME_ORIGINAL to "拍摄时间", ExifInterface.TAG_OFFSET_TIME_ORIGINAL to "时区",
                ExifInterface.TAG_EXPOSURE_TIME to "快门", ExifInterface.TAG_F_NUMBER to "光圈",
                ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY to "ISO", ExifInterface.TAG_FOCAL_LENGTH to "焦距",
                ExifInterface.TAG_LENS_MAKE to "镜头厂商", ExifInterface.TAG_LENS_MODEL to "镜头",
                ExifInterface.TAG_USER_COMMENT to "备注",
                ExifInterface.TAG_PIXEL_X_DIMENSION to "宽", ExifInterface.TAG_PIXEL_Y_DIMENSION to "高",
            ),
        )

        fun read(bytes: ByteArray): PhotoMetadata {
            val exif = runCatching { ExifInterface(ByteArrayInputStream(bytes)) }.getOrNull() ?: return PhotoMetadata(emptyList())
            val groups = mutableListOf<Pair<String, List<Pair<String, String>>>>()
            val gps = mutableListOf<Pair<String, String>>()
            exif.latLong?.let { (lat, lng) ->
                gps += "纬度" to "%.6f".format(lat)
                gps += "经度" to "%.6f".format(lng)
            }
            exif.getAttribute(ExifInterface.TAG_GPS_ALTITUDE)?.let { gps += "海拔" to it }
            exif.getAttribute(ExifInterface.TAG_GPS_DATESTAMP)?.let { gps += "GPS 日期" to it }
            if (gps.isNotEmpty()) groups += "位置" to gps
            for ((title, tags) in tagGroups) {
                val rows = tags.mapNotNull { (tag, name) -> exif.getAttribute(tag)?.takeIf { it.isNotBlank() }?.let { name to it } }
                if (rows.isNotEmpty()) groups += title to rows
            }
            return PhotoMetadata(groups)
        }

        /** 截图（"自动"格式下导出无损 PNG）还是相机照片（导出 JPEG） */
        fun isLikelyScreenshot(bytes: ByteArray): Boolean {
            val exif = runCatching { ExifInterface(ByteArrayInputStream(bytes)) }.getOrNull()
            val hasExposure = exif?.getAttribute(ExifInterface.TAG_EXPOSURE_TIME) != null ||
                exif?.getAttribute(ExifInterface.TAG_F_NUMBER) != null
            return com.example.redact.core.render.ImageKind.isLikelyScreenshot(
                bytes.copyOf(min(8, bytes.size)), exif?.getAttribute(ExifInterface.TAG_USER_COMMENT), hasExposure,
            )
        }
    }
}
