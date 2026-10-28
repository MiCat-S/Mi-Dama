// 一张待处理的图片：原图、识别结果、用户的勾选与样式。
// 创建很便宜（只保留压缩后的原图数据）；显示用图、缩略图、识别都在需要时于后台完成
package com.example.redact.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.IntSize
import com.example.redact.core.EditHistory
import com.example.redact.core.Finding
import com.example.redact.core.FindingKind
import com.example.redact.core.MaskStyle
import com.example.redact.core.detect.TextLine
import com.example.redact.core.render.ExportFormat
import com.example.redact.core.render.ExportSize
import com.example.redact.core.render.Redactor
import com.example.redact.core.render.RgbaImage
import com.example.redact.core.render.WatermarkSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.UUID

class RedactItem(
    val key: String,
    /** 原图文件数据（缩略图、显示用图、识别都从它按需解码） */
    private val bytes: ByteArray,
    /** 相册里的原图（从相册打开时才有），用于"保存后删除原图" */
    val mediaUri: Uri? = null,
    val mediaId: Long? = null,
    /** 原文件名（用来给导出文件起名） */
    val originalFilename: String? = null,
) {
    sealed interface Phase {
        /** 还没开始识别（进入编辑页时才开始） */
        data object Pending : Phase
        data object Detecting : Phase
        data object Ready : Phase
        data object Saved : Phase
        data class Failed(val reason: String) : Phase
    }

    val id: String = UUID.randomUUID().toString()

    /** 截图（"自动"格式下导出无损 PNG）还是相机照片（导出 JPEG） */
    val isScreenshot by lazy { PhotoMetadata.isLikelyScreenshot(bytes) }

    /** 原图自带的元数据，仅用于"查看 EXIF"，导出时一律丢弃 */
    val metadata by lazy { PhotoMetadata.read(bytes) }

    var phase by mutableStateOf<Phase>(Phase.Pending)

    /** 所有识别到 / 手动添加的区域。修改请走 edit 等方法，才能撤销 */
    var findings by mutableStateOf<List<Finding>>(emptyList())
        private set

    /** OCR 识别出的所有文字行（"文字"工具点一下盖住一整行） */
    var textLines: List<TextLine> = emptyList()
        private set

    /** 全局效果；null = 自动（按类别选默认效果）。单处在 Finding.style 里另外指定 */
    var styleOverride by mutableStateOf(Settings.style)
        private set

    /** 色块、杂讯色块的颜色 */
    var fillColor by mutableIntStateOf(Settings.fillColor)

    /** 识别、打码用的原图尺寸（坐标系）；解码前为 null */
    var size by mutableStateOf<IntSize?>(null)
        private set

    /** 屏幕显示用图（原图，未打码），离开编辑页时释放 */
    var display by mutableStateOf<TiledImage?>(null)
        private set

    /** 列表 / 缩略图条用的小图 */
    var thumbnail by mutableStateOf<ImageBitmap?>(null)
        private set

    val isDetecting get() = phase == Phase.Pending || phase == Phase.Detecting
    val enabledCount get() = findings.count { it.isEnabled }

    // 编辑（全部可撤销）

    /** 撤销 / 重做覆盖的内容：所有区域的勾选、样式、位置，以及全局效果 */
    private data class EditState(val findings: List<Finding>, val style: MaskStyle?)

    private val history = EditHistory<EditState>()

    /** 历史变化时加一，让 canUndo / canRedo 能被界面观察到 */
    private var historyTick by mutableIntStateOf(0)
    val canUndo get() = historyTick >= 0 && history.canUndo
    val canRedo get() = historyTick >= 0 && history.canRedo

    private val editState get() = EditState(findings, styleOverride)

    /** 一次可撤销的编辑 */
    fun edit(change: (List<Finding>) -> List<Finding>) {
        val before = editState
        findings = change(findings)
        history.record(before, editState)
        historyTick++
    }

    fun undo() {
        history.undo(editState)?.let(::apply)
        historyTick++
    }

    fun redo() {
        history.redo(editState)?.let(::apply)
        historyTick++
    }

    private fun apply(state: EditState) {
        findings = state.findings
        styleOverride = state.style
    }

    fun updateFinding(id: String, change: (Finding) -> Finding) = edit { list -> list.map { if (it.id == id) change(it) else it } }

    /** 整个类别一起开 / 关 */
    fun setFindings(kind: FindingKind, enabled: Boolean) =
        edit { list -> list.map { if (it.kind == kind) it.copy(isEnabled = enabled) else it } }

    fun addFinding(finding: Finding) = edit { it + finding }

    fun removeFinding(id: String) = edit { list -> list.filter { it.id != id } }

    /**
     * 全局效果
     * @param remember 记住作为下次的默认
     */
    fun setStyle(style: MaskStyle?, remember: Boolean = true) {
        val before = editState
        styleOverride = style
        if (remember) Settings.style = style
        history.record(before, editState)
        historyTick++
    }

    /** 自动识别出的区域（手动添加的不算）是否有任何一处在打码 */
    val isAutoRedactionOn get() = findings.any { it.kind != FindingKind.MANUAL && it.isEnabled }

    /** 自动打码总开关：关 = 所有自动识别的区域都不打码；开 = 恢复默认勾选（置信度足够的） */
    fun setAutoRedaction(on: Boolean) = edit { list ->
        list.map { if (it.kind == FindingKind.MANUAL) it else it.copy(isEnabled = on && it.confidence >= 0.5f) }
    }

    /** 各类别的数量和是否有勾选；数量相同时按类别固定顺序，避免点选后标签跳来跳去 */
    val kindCounts: List<Triple<FindingKind, Int, Boolean>>
        get() = findings.groupBy { it.kind }
            .map { (kind, list) -> Triple(kind, list.size, list.any { it.isEnabled }) }
            .sortedWith(compareByDescending<Triple<FindingKind, Int, Boolean>> { it.second }.thenBy { it.first.ordinal })

    /** 文字工具：点中的那一行已有整行打码就开 / 关它，否则加一个盖住整行的区域 */
    fun toggleTextLine(x: Float, y: Float): Boolean {
        val line = textLines.filter { it.rect.inset(-4f, -4f).contains(x, y) }.minByOrNull { it.rect.area } ?: return false
        val existing = findings.find { it.kind == FindingKind.MANUAL && it.rect.iou(line.rect) > 0.8f }
        if (existing != null) {
            updateFinding(existing.id) { it.copy(isEnabled = !it.isEnabled) }
        } else {
            addFinding(Finding(FindingKind.MANUAL, line.rect, 1f, line.text))
        }
        return true
    }

    // 图像

    private val sourceLock = Mutex()

    @Volatile
    private var cachedSource: RgbaImage? = null

    /** 正在显示这张图的编辑页数量（loadDisplay / releaseDisplay 成对调用），归零时释放大图 */
    private var displayUsers = 0

    suspend fun loadThumbnail() {
        if (thumbnail != null) return
        thumbnail = withContext(Dispatchers.Default) { Images.decode(bytes, maxSide = 256)?.asImageBitmap() }
    }

    /** 进入编辑页时调用，与 releaseDisplay 成对 */
    suspend fun loadDisplay() {
        displayUsers++
        if (display != null) return
        val image = withContext(Dispatchers.Default) {
            Images.decode(bytes, maxPixels = Images.MAX_DISPLAY_PIXELS)?.let(Images::tiles)
        }
        // 解码期间编辑页已经关掉：不留住这张大图
        if (displayUsers > 0) display = image
    }

    /** 离开编辑页时调用：大图只在看的时候占内存（还在跑的识别、渲染拿着旧的那份，用完自然释放） */
    fun releaseDisplay() {
        displayUsers--
        if (displayUsers > 0) return
        display = null
        cachedSource = null
    }

    /** 识别、预览、导出用的原图像素。编辑页显示期间缓存一份，避免每次改动都重新解码 */
    private suspend fun source(): RgbaImage = sourceLock.withLock {
        cachedSource?.let { return it }
        val bitmap = withContext(Dispatchers.Default) { Images.decode(bytes) } ?: error("无法读取这张图片")
        val img = withContext(Dispatchers.Default) { Images.toRgba(bitmap) }
        withContext(Dispatchers.Main) { size = IntSize(img.width, img.height) }
        if (displayUsers > 0) cachedSource = img
        img
    }

    // 识别

    private val detectLock = Mutex()

    /** 还没识别过就开始识别；正在识别则等它完成（多处同时调用只会识别一次） */
    suspend fun detectIfNeeded() = detectLock.withLock {
        if (phase != Phase.Pending) return@withLock
        phase = Phase.Detecting
        try {
            val result = withContext(Dispatchers.Default) {
                val bitmap = Images.decode(bytes) ?: error("无法读取这张图片")
                withContext(Dispatchers.Main) { size = IntSize(bitmap.width, bitmap.height) }
                if (displayUsers > 0) sourceLock.withLock { if (cachedSource == null) cachedSource = Images.toRgba(bitmap) }
                MlKitDetector.analyze(bitmap)
            }
            // 识别结果是起点，不算一次编辑
            findings = result.findings
            textLines = result.textLines
            history.reset()
            historyTick++
            phase = Phase.Ready
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) {
                phase = Phase.Pending
                throw e
            }
            phase = Phase.Failed(e.message ?: e.javaClass.simpleName)
        }
    }

    // 导出

    private val renderLock = Mutex()

    /**
     * 打码预览（后台渲染，像素数不超过显示用图）。同一时间只渲染一张：渲染中又有修改，
     * 新请求排在后面，开始时才读取状态；被界面取消的请求直接放弃
     */
    suspend fun renderPreview(watermark: WatermarkSpec?): TiledImage? = renderLock.withLock {
        val findings = findings
        val style = styleOverride
        val color = fillColor
        val src = source()
        withContext(Dispatchers.Default) {
            var bitmap = Images.toBitmap(Redactor(color).render(src, findings, style))
            bitmap = Images.fitPixels(bitmap, Images.MAX_DISPLAY_PIXELS)
            if (watermark != null) bitmap = Images.drawWatermark(bitmap, watermark)
            Images.tiles(bitmap)
        }
    }

    /** 当前勾选、样式和导出选项对应的导出任务（快照，可以放到后台执行） */
    fun export(settings: ExportSettings, size: ExportSize = settings.size.exportSize) = ExportJob(
        item = this, findings = findings, style = styleOverride, color = fillColor,
        watermark = settings.activeWatermark, size = size,
        format = settings.exportFormat(isScreenshot), filename = outputBaseName,
    )

    private val outputBaseName: String
        get() = originalFilename?.substringBeforeLast('.')?.takeIf { it.isNotBlank() } ?: "redact-${id.take(8)}"

    /**
     * 渲染 + 编码，不带任何元数据。
     * 顺序固定：先打码，再缩放（缩小永远不会发生在打码之前），最后在输出尺寸上加水印
     */
    class ExportJob(
        val item: RedactItem,
        val findings: List<Finding>,
        val style: MaskStyle?,
        val color: Int,
        val watermark: WatermarkSpec?,
        val size: ExportSize,
        val format: ExportFormat,
        val filename: String,
    ) {
        val outputFilename get() = "$filename$FILENAME_MARKER${format.extension}"

        suspend fun render() = run {
            val src = item.source()
            withContext(Dispatchers.Default) {
                var bitmap = Images.toBitmap(Redactor(color).render(src, findings, style))
                val (w, h) = size.apply(bitmap.width, bitmap.height)
                bitmap = Images.scale(bitmap, w, h)
                if (watermark != null) bitmap = Images.drawWatermark(bitmap, watermark)
                bitmap
            }
        }

        suspend fun encode(): ByteArray {
            val bitmap = render()
            return withContext(Dispatchers.Default) { Images.encode(bitmap, format) }
        }
    }

    companion object {
        /** 本 App 输出的文件名里都带这个标记：相册里据此认出输出图，打开 App 时不会再自动进入它 */
        const val FILENAME_MARKER = "-redacted."

        /** 读取图片数据（相册图片可能要从云端取回，由系统完成）；不是图片时返回 null */
        suspend fun load(context: Context, key: String, uri: Uri, mediaId: Long? = null): RedactItem? =
            withContext(Dispatchers.IO) {
                val bytes = Images.readBytes(context, uri) ?: return@withContext null
                val name = runCatching {
                    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst()) it.getString(0) else null
                    }
                }.getOrNull()
                val item = RedactItem(key, bytes, if (mediaId != null) uri else null, mediaId, name)
                item.loadThumbnail()
                if (item.thumbnail == null) null else item
            }
    }
}
