// 分享入口：在别的 App 里分享 / 编辑图片时选「截图打码」。
// 单张直接进编辑页（保存即结束），多张先列表再逐张编辑，或一次全部导出
package com.example.redact

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.IntentCompat
import com.example.redact.data.ItemStore
import com.example.redact.data.RedactItem
import com.example.redact.data.SaveReport
import com.example.redact.data.Settings
import com.example.redact.ui.ExportSheet
import com.example.redact.ui.RedactTheme
import com.example.redact.ui.ReportDialog
import com.example.redact.ui.ReviewScreen
import com.example.redact.ui.rememberTrashLauncher

class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.init(this)
        enableEdgeToEdge()
        val uris = sharedUris(intent)
        setContent {
            RedactTheme {
                Surface(Modifier.fillMaxSize()) {
                    Box(Modifier.safeDrawingPadding()) { ShareRoot(uris, onFinish = ::finish) }
                }
            }
        }
    }

    private fun sharedUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
        Intent.ACTION_SEND_MULTIPLE ->
            IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        else -> listOfNotNull(intent.data)
    }.take(20)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShareRoot(uris: List<Uri>, onFinish: () -> Unit) {
    val context = LocalContext.current
    val store = remember { ItemStore(context) }
    val items by produceState<List<RedactItem>?>(null) {
        value = uris.mapNotNull { store.item(ItemStore.keyFor(it)) }
    }
    var open by remember { mutableStateOf<RedactItem?>(null) }
    var exporting by remember { mutableStateOf(false) }
    var report by remember { mutableStateOf<SaveReport?>(null) }
    val trash = rememberTrashLauncher()

    /** 保存成功：提示一下就回到发起分享的 App */
    fun handleSaved(result: SaveReport) {
        if (result.outcome == SaveReport.Outcome.SUCCESS) {
            Toast.makeText(context, result.message, Toast.LENGTH_SHORT).show()
            onFinish()
        } else {
            report = result
        }
    }

    val list = items
    when {
        list == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        list.isEmpty() -> Column(
            Modifier.fillMaxSize().padding(32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("没有可打码的图片", style = MaterialTheme.typography.titleMedium)
            Text("请从相册或截图预览里分享图片。", textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = onFinish) { Text("关闭") }
        }
        list.size == 1 -> ReviewScreen(list[0], onBack = onFinish, onSaved = ::handleSaved)
        open != null -> {
            BackHandler { open = null }
            ReviewScreen(open!!, onBack = { open = null })
        }
        else -> Column(Modifier.fillMaxSize()) {
            LaunchedEffect(list) { for (item in list) item.detectIfNeeded() }
            TopAppBar(
                title = { Text("截图打码") },
                navigationIcon = { IconButton(onClick = onFinish) { Icon(Icons.Filled.Close, "取消") } },
                actions = {
                    TextButton(onClick = { exporting = true }, enabled = list.none { it.isDetecting }) { Text("全部导出") }
                },
            )
            LazyColumn {
                itemsIndexed(list, key = { _, it -> it.id }) { i, item ->
                    ListItem(
                        leadingContent = {
                            Box(Modifier.size(48.dp, 64.dp).clip(RoundedCornerShape(6.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh)) {
                                item.thumbnail?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
                            }
                        },
                        headlineContent = { Text(item.originalFilename ?: "图片 ${i + 1}") },
                        supportingContent = {
                            Text(
                                when (val p = item.phase) {
                                    RedactItem.Phase.Pending, RedactItem.Phase.Detecting -> "识别中…"
                                    RedactItem.Phase.Ready -> if (item.enabledCount > 0) "找到 ${item.enabledCount} 处" else "没有发现敏感信息"
                                    RedactItem.Phase.Saved -> "已保存"
                                    is RedactItem.Phase.Failed -> "识别失败：${p.reason}"
                                },
                            )
                        },
                        modifier = Modifier.clickable { open = item },
                    )
                }
            }
        }
    }
    if (exporting && list != null) {
        ExportSheet(list, trash, onDismiss = { exporting = false }, onSaved = ::handleSaved)
    }
    report?.let { ReportDialog(it) { report = null } }
}
