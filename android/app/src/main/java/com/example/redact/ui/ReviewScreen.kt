// 编辑页：进入即识别并直接显示打码结果
//  顶栏：返回 · 撤销 / 重做 · 帮助 · 分享（导出选项）· ✓ 按当前设置直接保存
//  画布：点阵画板上的图片卡片，双指缩放；底栏：[自动打码开关] [效果 | 文字 | 马克笔] [颜色]
package com.example.redact.ui

import android.app.Activity
import android.content.IntentSender
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.AutoFixOff
import androidx.compose.material.icons.filled.BorderColor
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Colorize
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.redact.core.MaskStyle
import com.example.redact.core.render.EffectPreview
import com.example.redact.data.Images
import com.example.redact.data.PhotoSaver
import com.example.redact.data.RedactItem
import com.example.redact.data.SaveReport
import com.example.redact.data.Settings
import com.example.redact.data.TiledImage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun ReviewScreen(
    item: RedactItem,
    onBack: (() -> Unit)?,
    /** 保存完成后的回调（批量模式跳到下一张、分享入口结束页面）；为 null 时成功后返回上一页 */
    onSaved: ((SaveReport) -> Unit)? = null,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptic = LocalHapticFeedback.current
    val settings = Settings.export
    val trash = rememberTrashLauncher()

    var rendered by remember(item.id) { mutableStateOf<TiledImage?>(null) }
    var tool by remember(item.id) { mutableStateOf<EditTool?>(null) }
    var toast by remember { mutableStateOf<String?>(null) }
    var report by remember { mutableStateOf<SaveReport?>(null) }
    var saving by remember { mutableStateOf(false) }
    var showExport by remember { mutableStateOf(false) }
    var showHelp by remember { mutableStateOf(false) }
    var showColors by remember { mutableStateOf(false) }

    val onEdit = { haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove) }

    LaunchedEffect(item.id) { item.loadDisplay() }
    DisposableEffect(item.id) { onDispose { item.releaseDisplay() } }
    LaunchedEffect(item.id) {
        item.detectIfNeeded()
        toast = when (val p = item.phase) {
            RedactItem.Phase.Ready ->
                if (item.enabledCount > 0) "找到 ${item.enabledCount} 处" else "没有发现敏感信息，可用下方工具手动打码"
            is RedactItem.Phase.Failed -> "识别失败：${p.reason}"
            else -> null
        }
    }
    // 所见即所得：勾选、效果、颜色、水印变化后重新渲染；渲染期间保留上一张，不闪烁
    val watermark = settings.activeWatermark
    LaunchedEffect(item.id, item.isDetecting, item.display != null, item.findings, item.styleOverride, item.fillColor, watermark) {
        if (item.isDetecting || item.display == null) return@LaunchedEffect
        runCatching { item.renderPreview(watermark) }.getOrNull()?.let { rendered = it }
    }
    LaunchedEffect(toast) {
        if (toast != null) {
            delay(2200)
            toast = null
        }
    }

    fun handleSaved(result: SaveReport) {
        if (onSaved != null) {
            onSaved(result)
        } else if (result.outcome == SaveReport.Outcome.SUCCESS) {
            toast = result.message
            haptic.performHapticFeedback(HapticFeedbackType.Confirm)
            // 成功后稍等一下让用户看到提示，再回到相册
            scope.launch {
                delay(800)
                onBack?.invoke()
            }
        } else {
            report = result
        }
    }

    /** ✓：按当前导出设置直接保存，不再弹选项 */
    fun quickSave() = scope.launch {
        saving = true
        val deleting = settings.deleteOriginal && item.mediaUri != null
        val result = PhotoSaver.saveAll(context, listOf(item), deleting, trash::request)
        saving = false
        handleSaved(result)
    }

    Box(Modifier.fillMaxSize()) {
        DotGridBackground(Modifier.fillMaxSize())
        Column(Modifier.fillMaxSize()) {
            ReviewTopBar(
                item = item, saving = saving, onBack = onBack,
                onHelp = { showHelp = true }, onShare = { showExport = true }, onDone = { quickSave() },
            )
            Box(Modifier.weight(1f).fillMaxWidth()) {
                ReviewCanvas(
                    item = item, rendered = rendered, tool = tool, editable = !item.isDetecting && !saving,
                    onEdit = onEdit,
                    onPickColor = { x, y ->
                        sampleColor(item, x, y)?.let {
                            item.fillColor = it
                            Settings.fillColor = it
                            onEdit()
                        }
                        tool = null
                    },
                    modifier = Modifier.fillMaxSize(),
                )
                if (item.display == null) {
                    ProgressLabel("正在读取图片…", Modifier.align(Alignment.Center))
                } else if (item.isDetecting) {
                    ProgressLabel("识别中…", Modifier.align(Alignment.Center))
                }
                if (tool == EditTool.EYEDROPPER) {
                    Hint("点一下图片，吸取那里的颜色", Modifier.align(Alignment.TopCenter).padding(top = 8.dp))
                }
                toast?.let { Hint(it, Modifier.align(Alignment.TopCenter).padding(top = 8.dp), icon = true) }
            }
            ReviewBottomBar(
                item = item, tool = tool, onTool = { tool = it }, onEdit = onEdit,
                onColor = { showColors = true },
            )
        }
    }

    if (showExport) {
        ExportSheet(items = listOf(item), trash = trash, onDismiss = { showExport = false }, onSaved = { handleSaved(it) })
    }
    if (showHelp) HelpSheet(onDismiss = { showHelp = false })
    if (showColors) {
        ColorSheet(
            color = item.fillColor,
            onColor = {
                item.fillColor = it
                Settings.fillColor = it
            },
            onEyedropper = {
                showColors = false
                tool = EditTool.EYEDROPPER
            },
            onDismiss = { showColors = false },
        )
    }
    report?.let { ReportDialog(it) { report = null } }
}

/** 取色器：从原图（未打码的显示图）取颜色 */
private fun sampleColor(item: RedactItem, x: Float, y: Float): Int? {
    val display = item.display ?: return null
    val coords = item.size ?: return null
    val dx = (x * display.width / coords.width).toInt().coerceIn(0, display.width - 1)
    val dy = (y * display.height / coords.height).toInt().coerceIn(0, display.height - 1)
    val (top, tile) = display.tiles.last { it.first <= dy }
    return tile.asAndroidBitmap().getPixel(dx, (dy - top).coerceIn(0, tile.height - 1)) or (0xFF shl 24)
}

@Composable
private fun ReviewTopBar(
    item: RedactItem, saving: Boolean, onBack: (() -> Unit)?,
    onHelp: () -> Unit, onShare: () -> Unit, onDone: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") }
        IconButton(onClick = { item.undo() }, enabled = item.canUndo) { Icon(Icons.AutoMirrored.Filled.Undo, "撤销") }
        IconButton(onClick = { item.redo() }, enabled = item.canRedo) { Icon(Icons.AutoMirrored.Filled.Redo, "重做") }
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onHelp) { Icon(Icons.AutoMirrored.Outlined.HelpOutline, "帮助") }
        IconButton(onClick = onShare, enabled = !item.isDetecting) { Icon(Icons.Outlined.Share, "导出选项") }
        FilledIconButton(
            onClick = onDone, enabled = !item.isDetecting && !saving,
            colors = IconButtonDefaults.filledIconButtonColors(containerColor = SaveGreen, contentColor = Color.White),
            modifier = Modifier.padding(horizontal = 8.dp),
        ) {
            if (saving) CircularProgressIndicator(Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
            else Icon(Icons.Filled.Check, "保存到相册")
        }
    }
}

@Composable
private fun ReviewBottomBar(
    item: RedactItem, tool: EditTool?, onTool: (EditTool?) -> Unit, onEdit: () -> Unit, onColor: () -> Unit,
) {
    val editable = !item.isDetecting
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AutoRedactButton(item, editable, onEdit)
        Spacer(Modifier.weight(1f))
        Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, shadowElevation = 3.dp) {
            Row(
                Modifier.height(56.dp).padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                EffectMenu(item, editable, onEdit)
                ToolButton(tool == EditTool.TEXT, editable, "文字", { onTool(if (tool == EditTool.TEXT) null else EditTool.TEXT) }) {
                    // 固定显示 "Aa"
                    Text("Aa", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                }
                ToolButton(tool == EditTool.MARKER, editable, "马克笔", { onTool(if (tool == EditTool.MARKER) null else EditTool.MARKER) }) {
                    Icon(Icons.Filled.BorderColor, null)
                }
            }
        }
        Spacer(Modifier.weight(1f))
        FillColorButton(item.fillColor, enabled = item.styleOverride?.usesColor == true, onClick = onColor)
    }
}

/** 左侧圆形按钮：点一下全部开 / 关自动打码；长按按类别开关 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun AutoRedactButton(item: RedactItem, enabled: Boolean, onEdit: () -> Unit) {
    val on = item.isAutoRedactionOn
    var menu by remember { mutableStateOf(false) }
    Box {
        Surface(
            shape = CircleShape,
            color = if (on) SaveGreen else MaterialTheme.colorScheme.surfaceContainerHigh,
            shadowElevation = 3.dp,
            modifier = Modifier.size(56.dp).alpha(if (enabled) 1f else 0.5f).clip(CircleShape).combinedClickable(
                enabled = enabled,
                onClickLabel = if (on) "关闭全部自动打码" else "打开全部自动打码",
                onLongClick = { menu = true },
                onClick = {
                    item.setAutoRedaction(!on)
                    onEdit()
                },
            ),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    if (on) Icons.Filled.AutoFixHigh else Icons.Filled.AutoFixOff,
                    if (on) "自动打码：开" else "自动打码：关",
                    tint = if (on) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            val kinds = item.kindCounts.filter { it.first != com.example.redact.core.FindingKind.MANUAL }
            if (kinds.isEmpty()) DropdownMenuItem(text = { Text("没有识别到内容") }, onClick = { menu = false }, enabled = false)
            for ((kind, count, kindOn) in kinds) {
                DropdownMenuItem(
                    text = { Text("${kind.label}（$count）") },
                    leadingIcon = { if (kindOn) Icon(Icons.Filled.Check, null) else Spacer(Modifier.size(24.dp)) },
                    onClick = {
                        item.setFindings(kind, !kindOn)
                        onEdit()
                    },
                )
            }
        }
    }
}

/** 当前效果 + 向上弹出的效果菜单，每项带真实效果小样 */
@Composable
private fun EffectMenu(item: RedactItem, enabled: Boolean, onEdit: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.clip(RoundedCornerShape(10.dp)).alpha(if (enabled) 1f else 0.5f).clickable(enabled = enabled) { menu = true }.padding(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Swatch(item.styleOverride, item.fillColor, 30)
            Icon(Icons.Filled.KeyboardArrowUp, "打码效果：${item.styleOverride?.label ?: "自动"}", Modifier.size(18.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            val choices: List<Pair<MaskStyle?, String>> = listOf(null to "自动") + MaskStyle.entries.map { it to it.label }
            for ((style, label) in choices) {
                DropdownMenuItem(
                    text = { Text(label) },
                    leadingIcon = { Swatch(style, item.fillColor, 28) },
                    trailingIcon = { if (item.styleOverride == style) Icon(Icons.Filled.Check, null) },
                    onClick = {
                        item.setStyle(style)
                        onEdit()
                        menu = false
                    },
                )
            }
        }
    }
}

/** 效果小样（真实渲染，按 效果-颜色-尺寸 缓存） */
@Composable
fun Swatch(style: MaskStyle?, color: Int, sizeDp: Int) {
    val density = androidx.compose.ui.platform.LocalDensity.current
    val px = with(density) { sizeDp.dp.roundToPx() }
    val image = remember(style, color, px) { swatchImage(style, color, px) }
    Image(image, null, Modifier.size(sizeDp.dp).clip(RoundedCornerShape(6.dp)))
}

private val swatchCache = HashMap<String, ImageBitmap>()

private fun swatchImage(style: MaskStyle?, color: Int, px: Int): ImageBitmap =
    swatchCache.getOrPut("${style?.name}-$color-$px") {
        Images.toBitmap(EffectPreview.swatch(style, color, px)).asImageBitmap()
    }

/** 工具按钮：再点一次取消（回到"点区域开关"的普通模式） */
@Composable
private fun ToolButton(selected: Boolean, enabled: Boolean, label: String, onClick: () -> Unit, content: @Composable () -> Unit) {
    IconButton(
        onClick = onClick, enabled = enabled,
        colors = if (selected) IconButtonDefaults.filledIconButtonColors() else IconButtonDefaults.iconButtonColors(),
        modifier = Modifier.size(44.dp).semantics {
            contentDescription = label
            this.selected = selected
        },
    ) { content() }
}

/** 右侧圆形按钮：色块颜色（彩色圆环），只在色块 / 杂讯色块效果下可用 */
@Composable
private fun FillColorButton(color: Int, enabled: Boolean, onClick: () -> Unit) {
    val ring = Brush.sweepGradient(listOf(Color.Red, Color.Yellow, Color.Green, Color.Cyan, Color.Blue, Color.Magenta, Color.Red))
    Surface(
        shape = CircleShape, color = MaterialTheme.colorScheme.surfaceContainerHigh, shadowElevation = 3.dp,
        onClick = onClick, enabled = enabled,
        modifier = Modifier.size(56.dp).alpha(if (enabled) 1f else 0.4f),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Box(Modifier.size(30.dp).border(3.dp, ring, CircleShape).padding(5.dp).background(Color(color), CircleShape))
        }
    }
}

@Composable
private fun ProgressLabel(text: String, modifier: Modifier = Modifier) {
    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerHighest, shadowElevation = 4.dp, modifier = modifier) {
        Row(Modifier.padding(horizontal = 18.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(12.dp))
            Text(text)
        }
    }
}

@Composable
fun Hint(text: String, modifier: Modifier = Modifier, icon: Boolean = false) {
    Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.inverseSurface, modifier = modifier) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (icon) {
                Icon(Icons.Outlined.VerifiedUser, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.inverseOnSurface)
                Spacer(Modifier.width(6.dp))
            }
            Text(text, color = MaterialTheme.colorScheme.inverseOnSurface, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
fun ReportDialog(report: SaveReport, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(if (report.outcome == SaveReport.Outcome.FAILURE) Icons.Outlined.Info else Icons.Filled.Check, null) },
        text = { Text(report.message) },
        confirmButton = { TextButton(onClick = onDismiss) { Text("好") } },
    )
}

// 颜色

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ColorSheet(color: Int, onColor: (Int) -> Unit, onEyedropper: () -> Unit, onDismiss: () -> Unit) {
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text("色块颜色", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(12.dp))
            ColorPaletteRow(color, onColor)
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = onEyedropper) {
                Icon(Icons.Filled.Colorize, null)
                Spacer(Modifier.width(8.dp))
                Text("从图上吸取颜色")
            }
            HsvSliders(color, onColor)
        }
    }
}

/** 把保存流程里的"移到回收站"请求交给系统确认框，挂起等用户的选择 */
class TrashLauncher {
    internal var pending: CompletableDeferred<Boolean>? = null
    internal lateinit var launch: (IntentSenderRequest) -> Unit

    suspend fun request(sender: IntentSender): Boolean {
        val d = CompletableDeferred<Boolean>()
        pending = d
        launch(IntentSenderRequest.Builder(sender).build())
        return d.await()
    }
}

@Composable
fun rememberTrashLauncher(): TrashLauncher {
    val state = remember { TrashLauncher() }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {
        state.pending?.complete(it.resultCode == Activity.RESULT_OK)
        state.pending = null
    }
    state.launch = { launcher.launch(it) }
    return state
}
