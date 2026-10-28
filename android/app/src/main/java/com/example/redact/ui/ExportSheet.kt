// 导出：一个面板里选好格式、大小、水印、是否删除原图，然后直接保存或分享。
// 每次导出都会看到这些选项；上次的选择会被记住作为默认值
package com.example.redact.ui

import android.graphics.Color.HSVToColor
import android.graphics.Color.colorToHSV
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.BorderColor
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material.icons.outlined.ZoomIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.example.redact.core.render.HexColor
import com.example.redact.data.PhotoSaver
import com.example.redact.data.RedactItem
import com.example.redact.data.SaveReport
import com.example.redact.data.Settings
import com.example.redact.data.TiledImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportSheet(
    items: List<RedactItem>,
    trash: TrashLauncher,
    onDismiss: () -> Unit,
    /** 保存由面板自己完成并关闭；结果交给弹出方显示（分享入口据此直接结束页面） */
    onSaved: (SaveReport) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings = Settings.export
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var saved by remember { mutableStateOf<Int?>(null) }
    var sharing by remember { mutableStateOf(false) }
    var showExif by remember { mutableStateOf(false) }
    val first = items.firstOrNull()
    val canDeleteOriginals = items.any { it.mediaUri != null }

    fun changed() = settings.persist()

    ModalBottomSheet(
        onDismissRequest = { if (saved == null) onDismiss() },
        sheetState = sheet,
    ) {
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(if (items.size == 1) "导出" else "导出 ${items.size} 张", style = MaterialTheme.typography.titleLarge)

            // 缩略预览：水印一改就重新渲染，一眼可见
            var preview by remember { mutableStateOf<TiledImage?>(null) }
            val watermark = settings.activeWatermark
            LaunchedEffect(watermark) {
                delay(150)   // 拖动滑杆时不要每一帧都重渲染
                first?.let { item -> runCatching { item.renderPreview(watermark) }.getOrNull()?.let { preview = it } }
            }
            Box(Modifier.fillMaxWidth().height(220.dp), contentAlignment = Alignment.Center) {
                val p = preview
                if (p == null) CircularProgressIndicator() else TiledPreview(p, Modifier.clip(RoundedCornerShape(8.dp)))
            }

            Dropdown("格式", settings.format.label, ExportSettingsChoices.formats) { settings.format = it; changed() }
            Dropdown("大小", settings.size.label, ExportSettingsChoices.sizes) { settings.size = it; changed() }
            if (first != null) {
                val size = first.size
                val ext = settings.exportFormat(first.isScreenshot).extension.uppercase()
                val text = if (items.size == 1 && size != null) {
                    val (w, h) = settings.size.exportSize.apply(size.width, size.height)
                    "导出为 $w × $h，$ext。缩放在打码之后进行，不会削弱打码。"
                } else "共 ${items.size} 张。缩放在打码之后进行，不会削弱打码。"
                Footnote(text)
            }

            HorizontalDivider()
            SwitchRow("水印", settings.watermarkEnabled) { settings.watermarkEnabled = it; changed() }
            if (settings.watermarkEnabled) {
                val w = settings.watermark
                OutlinedTextField(
                    value = w.text, onValueChange = { settings.watermark = w.copy(text = it); changed() },
                    placeholder = { Text("水印文字，例如：仅供办理 XX 业务使用") }, modifier = Modifier.fillMaxWidth(),
                )
                LabeledSlider("大小", w.fontScale, 0.02f..0.1f, "${(w.fontScale * 1000).toInt()}") { settings.watermark = w.copy(fontScale = it); changed() }
                LabeledSlider("不透明度", w.opacity, 0.05f..0.8f, "${(w.opacity * 100).toInt()}%") { settings.watermark = w.copy(opacity = it); changed() }
                LabeledSlider("角度", w.angleDegrees, -60f..60f, "${w.angleDegrees.toInt()}°") { settings.watermark = w.copy(angleDegrees = it); changed() }
                LabeledSlider("间距", w.spacing, 0.5f..5f, "%.1f".format(w.spacing)) { settings.watermark = w.copy(spacing = it); changed() }
                ColorPaletteRow(HexColor.parse(w.colorHex)) { settings.watermark = w.copy(colorHex = HexColor.format(it)); changed() }
            }
            Footnote("给证件照注明用途，防止被挪作他用。")

            // 从相册以外（分享、系统选择器）打开的图没有原图可删
            if (canDeleteOriginals) {
                HorizontalDivider()
                SwitchRow("保存后删除原图", settings.deleteOriginal) { settings.deleteOriginal = it; changed() }
                Footnote("保存后把相册里的原图移到回收站，系统会先请你确认（需要 Android 11 或更新）。")
            }

            if (items.size == 1 && first != null) {
                HorizontalDivider()
                ListItem(
                    headlineContent = { Text("查看原图 EXIF") },
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.ArrowForward, null) },
                    modifier = Modifier.clickable { showExif = true },
                )
                Footnote("导出的图片只保留像素，不含位置、设备、拍摄时间等信息。")
            }

            val n = saved
            if (n != null) {
                Text("保存中 $n/${items.size}", style = MaterialTheme.typography.bodySmall)
                LinearProgressIndicator(progress = { n.toFloat() / items.size.coerceAtLeast(1) }, modifier = Modifier.fillMaxWidth())
            } else {
                Button(
                    onClick = {
                        scope.launch {
                            saved = 0
                            val report = PhotoSaver.saveAll(context, items, settings.deleteOriginal && canDeleteOriginals, trash::request) { saved = it }
                            saved = null
                            sheet.hide()
                            onDismiss()
                            onSaved(report)
                        }
                    },
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                ) {
                    Icon(Icons.Outlined.Download, null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (items.size == 1) "保存到相册" else "全部保存到相册（${items.size} 张）")
                }
                OutlinedButton(
                    onClick = {
                        scope.launch {
                            sharing = true
                            val intent = runCatching { PhotoSaver.shareIntent(context, items) }.getOrNull()
                            sharing = false
                            intent?.let { context.startActivity(it) }
                        }
                    },
                    enabled = !sharing,
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                ) {
                    if (sharing) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    else Icon(Icons.Outlined.Share, null)
                    Spacer(Modifier.width(8.dp))
                    Text("分享…")
                }
            }
        }
    }
    if (showExif && first != null) MetadataDialog(first) { showExif = false }
}

private object ExportSettingsChoices {
    val formats = com.example.redact.data.ExportSettings.FormatChoice.entries.map { it to it.label }
    val sizes = com.example.redact.data.ExportSettings.SizeChoice.entries.map { it to it.label }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> Dropdown(label: String, current: String, options: List<Pair<T, String>>, onSelect: (T) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = current, onValueChange = {}, readOnly = true, label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(androidx.compose.material3.ExposedDropdownMenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for ((value, text) in options) {
                DropdownMenuItem(text = { Text(text) }, onClick = {
                    onSelect(value)
                    expanded = false
                })
            }
        }
    }
}

@Composable
private fun SwitchRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Switch(checked, onChange)
    }
}

@Composable
private fun LabeledSlider(title: String, value: Float, range: ClosedFloatingPointRange<Float>, display: String, onChange: (Float) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.width(72.dp))
        Slider(value, onChange, valueRange = range, modifier = Modifier.weight(1f))
        Text(display, Modifier.width(48.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun Footnote(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** 按图片宽高比显示一张（可能分条的）预览图 */
@Composable
private fun TiledPreview(image: TiledImage, modifier: Modifier = Modifier) {
    val aspect = image.width.toFloat() / image.height
    Canvas(modifier.height(220.dp).width((220 * aspect).dp.coerceAtMost(320.dp))) {
        val k = size.height / image.height
        val w = image.width * k
        val left = (size.width - w) / 2
        for ((y, tile) in image.tiles) {
            drawImage(
                tile,
                dstOffset = androidx.compose.ui.unit.IntOffset(left.toInt(), (y * k).toInt()),
                dstSize = androidx.compose.ui.unit.IntSize(w.toInt(), (tile.height * k).toInt().coerceAtLeast(1)),
            )
        }
    }
}

/** 颜色选择行：预设色（打码色块和水印共用） */
@Composable
fun ColorPaletteRow(color: Int, onColor: (Int) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        for ((name, hex) in Settings.PALETTE) {
            val c = HexColor.parse(hex)
            val selected = (c and 0xFFFFFF) == (color and 0xFFFFFF)
            Box(
                Modifier.size(36.dp)
                    .border(if (selected) 3.dp else 0.dp, if (selected) MaterialTheme.colorScheme.primary else Color.Transparent, CircleShape)
                    .padding(4.dp)
                    .clip(CircleShape)
                    .border(1.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                    .clickable(onClickLabel = name) { onColor(c) },
            ) {
                Canvas(Modifier.size(28.dp)) { drawCircle(Color(c)) }
            }
        }
    }
}

/** 自定义颜色：色相 / 饱和度 / 亮度三条滑杆 */
@Composable
fun HsvSliders(color: Int, onColor: (Int) -> Unit) {
    val hsv = remember(color) { FloatArray(3).also { colorToHSV(color, it) } }
    fun emit(h: Float = hsv[0], s: Float = hsv[1], v: Float = hsv[2]) = onColor(HSVToColor(floatArrayOf(h, s, v)))
    Column {
        val hues = (0..6).map { Color.hsv(it * 60f % 360f, 1f, 1f) }
        GradientSlider("色相", hsv[0], 0f..360f, Brush.horizontalGradient(hues)) { emit(h = it) }
        GradientSlider("饱和度", hsv[1], 0f..1f, Brush.horizontalGradient(listOf(Color.White, Color.hsv(hsv[0], 1f, 1f)))) { emit(s = it) }
        GradientSlider("亮度", hsv[2], 0f..1f, Brush.horizontalGradient(listOf(Color.Black, Color.hsv(hsv[0], hsv[1], 1f)))) { emit(v = it) }
    }
}

@Composable
private fun GradientSlider(title: String, value: Float, range: ClosedFloatingPointRange<Float>, brush: Brush, onChange: (Float) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.width(56.dp))
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxWidth().height(6.dp).padding(horizontal = 10.dp)) { drawRoundRect(brush, cornerRadius = androidx.compose.ui.geometry.CornerRadius(3.dp.toPx())) }
            Slider(value, onChange, valueRange = range)
        }
    }
}

/** 原图元数据：让用户看到"如果不打码直接发出去，会泄露哪些信息" */
@Composable
private fun MetadataDialog(item: RedactItem, onDismiss: () -> Unit) {
    val meta = item.metadata
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("原图 EXIF") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.VerifiedUser, null, tint = SaveGreen)
                    Spacer(Modifier.width(8.dp))
                    Text(if (meta.hasSensitive) "导出的文件不包含以下任何信息" else "原图不含位置或设备信息", color = SaveGreen)
                }
                for ((group, rows) in meta.groups) {
                    Spacer(Modifier.height(12.dp))
                    Text(group, fontWeight = FontWeight.SemiBold)
                    for ((k, v) in rows) {
                        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                            Text(k, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(v)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("好") } },
    )
}

/** 「?」帮助：编辑页的手势和按钮说明 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HelpSheet(onDismiss: () -> Unit) {
    val rows: List<Triple<ImageVector?, String, String>> = listOf(
        Triple(Icons.Outlined.TouchApp, "点一下打码区域", "取消这一处，露出原图并留一圈虚线；再点一下恢复"),
        Triple(Icons.Outlined.TouchApp, "长按打码区域", "单独给这一处换效果，或删除手动加的框"),
        Triple(Icons.Filled.AutoFixHigh, "左下角魔术棒", "点一下开 / 关全部自动打码；长按按类别开关"),
        Triple(null, "文字工具", "点一下任意一行文字，整行盖住；再点一下取消"),
        Triple(Icons.Filled.BorderColor, "马克笔", "拖出一个框，盖住任意区域"),
        Triple(Icons.Outlined.ZoomIn, "双指缩放 / 双击", "放大看小字，双击在原大小和放大之间切换"),
        Triple(Icons.AutoMirrored.Filled.Undo, "撤销 / 重做", "所有改动都可以撤销"),
        Triple(Icons.Filled.CheckCircle, "绿色对勾", "按当前导出设置直接存到相册"),
        Triple(Icons.Outlined.Share, "分享按钮", "选格式、大小、水印、是否删原图，再保存或分享"),
    )
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text("怎么用", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = 20.dp))
        Column(Modifier.verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            for ((icon, title, detail) in rows) {
                ListItem(
                    leadingContent = {
                        if (icon != null) Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
                        else Text("Aa", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold)
                    },
                    headlineContent = { Text(title, fontWeight = FontWeight.Medium) },
                    supportingContent = { Text(detail) },
                )
            }
        }
    }
}
