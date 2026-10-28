// ML Kit 识别：OCR（中英文）、人脸、二维码 / 条码，全部用打包进 App 的模型，在本机完成。
// 长截图按竖向分段识别：整张送进去会被缩小，小字就丢了
package com.example.redact.data

import android.graphics.Bitmap
import com.example.redact.core.Rect
import com.example.redact.core.detect.DetectionPipeline
import com.example.redact.core.detect.DetectionResult
import com.example.redact.core.detect.RecognizedLine
import com.example.redact.core.detect.VisionResult
import com.example.redact.core.render.RgbaImage
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import kotlinx.coroutines.tasks.await
import kotlin.math.max
import kotlin.math.min
import android.graphics.Rect as AndroidRect

object MlKitDetector {
    /** 分段高度 = 宽度 × 该系数 */
    private const val TILE_ASPECT = 2.2f

    private val text by lazy { TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build()) }
    private val faces by lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                .setMinFaceSize(0.05f)
                .build(),
        )
    }
    private val codes by lazy { BarcodeScanning.getClient() }

    /** 识别 + 规则 + 聊天布局分析，返回原图像素坐标的结果 */
    suspend fun analyze(bitmap: Bitmap): DetectionResult {
        val vision = detect(bitmap)
        val scale = DetectionPipeline.workingScale(bitmap.width)
        val small = Images.toRgba(Images.scale(bitmap, max(1, (bitmap.width * scale).toInt()), max(1, (bitmap.height * scale).toInt())))
        return DetectionPipeline.analyze(vision, small, scale, bitmap.width, bitmap.height)
    }

    suspend fun detect(bitmap: Bitmap): VisionResult {
        val whole = InputImage.fromBitmap(bitmap, 0)
        val faceResults = faces.process(whole).await().map { it.boundingBox.toRect() to 0.9f }
        val codeResults = codes.process(whole).await().mapNotNull { b ->
            b.boundingBox?.let { it.toRect() to (b.format == Barcode.FORMAT_QR_CODE) }
        }

        // OCR 按竖向分段，段间重叠 8%，重叠区的重复行去掉
        val w = bitmap.width
        val h = bitmap.height
        val tileH = min(h, (w * TILE_ASPECT).toInt())
        val step = max(1, (tileH * 0.92f).toInt())
        val lines = mutableListOf<RecognizedLine>()
        var top = 0
        while (true) {
            val height = min(tileH, h - top)
            val tile = if (top == 0 && height == h) bitmap else Bitmap.createBitmap(bitmap, 0, top, w, height)
            val result = text.process(InputImage.fromBitmap(tile, 0)).await()
            val pixels = Images.toRgba(tile)
            for (line in result.textBlocks.flatMap { it.lines }) {
                val l = recognizedLine(line, top, pixels) ?: continue
                if (lines.none { it.rect.iou(l.rect) > 0.5f && it.text == l.text }) lines += l
            }
            if (top + height >= h) break
            top += step
        }
        return VisionResult(lines, faceResults, codeResults)
    }

    /** @param tile 这一段的像素（行框坐标相对这一段），用来找被 OCR 吞掉的空格 */
    private fun recognizedLine(line: Text.Line, dy: Int, tile: RgbaImage): RecognizedLine? {
        val box = line.boundingBox?.toRect(dy) ?: return null
        // 有逐字结果时按字间距补回空格（中文识别会吞掉空格）；拼出来和整行文字对不上就按原文
        val symbols = line.elements.flatMap { it.symbols }.mapNotNull { sym -> sym.boundingBox?.let { sym.text to it.toRect(dy) } }
        val plain = line.text.filterNot { it.isWhitespace() }
        if (symbols.isNotEmpty() && symbols.joinToString("") { it.first } == plain) {
            val gaps = RecognizedLine.blankGapCenters(tile, box.offset(0f, -dy.toFloat()))
            return RecognizedLine.fromSymbols(symbols, line.confidence, box, gaps)
        }
        return RecognizedLine(line.text, line.confidence, box, charBoxes(line, line.text, dy))
    }

    /**
     * 每个字符的框：按顺序把 OCR 的字符（Symbol）对齐到整行文字上；某个词没有字符级结果时，
     * 在词框里按字符宽度插值。对不上（OCR 的行文字和词不一致）就放弃，交给按比例插值的兜底
     */
    private fun charBoxes(line: Text.Line, s: String, dy: Int): List<Rect?>? {
        val boxes = arrayOfNulls<Rect>(s.length)
        var idx = 0
        for (el in line.elements) {
            val elBox = el.boundingBox ?: return null
            val pos = s.indexOf(el.text, idx)
            if (pos < 0 || pos - idx > 2) return null
            val symbols = el.symbols
            if (symbols.isNotEmpty() && symbols.joinToString("") { it.text } == el.text) {
                var k = pos
                for (sym in symbols) {
                    val r = sym.boundingBox?.toRect(dy)
                    for (j in sym.text.indices) boxes[k + j] = r
                    k += sym.text.length
                }
            } else {
                val r = elBox.toRect(dy)
                val weights = el.text.map { if (it.code < 128) 0.55f else 1f }
                val total = weights.sum()
                var acc = 0f
                for ((j, wgt) in weights.withIndex()) {
                    boxes[pos + j] = Rect(r.x + r.width * acc / total, r.y, r.width * wgt / total, r.height)
                    acc += wgt
                }
            }
            idx = pos + el.text.length
        }
        return boxes.toList()
    }

    private fun AndroidRect.toRect(dy: Int = 0) = Rect(left.toFloat(), (top + dy).toFloat(), width().toFloat(), height().toFloat())
}
