// 首页 = 相册：打开 App 直接进入最新一张待打码的图片（进入后自动识别），返回即是相册网格。
// 权限：系统弹窗里可选「允许全部 / 选择照片 / 不允许」；拒绝时仍可用系统照片选择器手动选图
package com.example.redact.ui

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.provider.Settings as AndroidSettings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Photo
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.redact.data.ItemStore
import com.example.redact.data.PhotoLibrary
import com.example.redact.data.RedactItem
import com.example.redact.data.SaveReport
import com.example.redact.data.Settings
import kotlinx.coroutines.launch

/** 一张时直接编辑；多张时进入批量（顶部缩略图条切换） */
data class ReviewRoute(val keys: List<String>)

class MainModel(app: Application) : AndroidViewModel(app) {
    val library = PhotoLibrary(app)
    val store = ItemStore(app)
    val routes = mutableStateListOf<ReviewRoute>()
    var launched = false

    init {
        library.observe { viewModelScope.launch { library.reload() } }
    }

    /** 在相册页，或者正在看的那张已经保存过了，才允许自动跳转（不打断正在编辑的图） */
    val canAutoNavigate: Boolean
        get() {
            val last = routes.lastOrNull() ?: return true
            val key = last.keys.singleOrNull() ?: return false
            return store.cached(key)?.phase == RedactItem.Phase.Saved
        }

    /** @param onlyIfNew 从后台回来时只在出现了新的待打码图片时才打开，避免用户退回相册后又被拉进去 */
    suspend fun openLatest(onlyIfNew: Boolean) {
        if (!Settings.openLatestOnLaunch || !canAutoNavigate) return
        val asset = library.latestUnprocessed() ?: return
        // 查找期间用户可能已经点进了别的图：找到后再确认一次
        if (!canAutoNavigate || (onlyIfNew && asset.key == Settings.lastAutoOpened)) return
        Settings.lastAutoOpened = asset.key
        routes.clear()
        routes += ReviewRoute(listOf(asset.key))
    }

    override fun onCleared() = library.stopObserving()
}

@Composable
fun MainApp() {
    val model: MainModel = viewModel()
    val route = model.routes.lastOrNull()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        if (model.launched) return@LaunchedEffect
        model.library.reload()
        model.openLatest(onlyIfNew = false)
        model.launched = true
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && model.launched) {
                model.library.refreshAccess()
                scope.launch {
                    model.library.reload()
                    model.openLatest(onlyIfNew = true)
                }
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    BackHandler(enabled = route != null) { model.routes.removeAt(model.routes.lastIndex) }
    val back = { if (model.routes.isNotEmpty()) model.routes.removeAt(model.routes.lastIndex) }
    when {
        route == null -> LibraryScreen(model)
        route.keys.size == 1 -> ReviewContainer(route.keys[0], model.store, onBack = { back() })
        else -> BatchReview(route.keys, model.store, onBack = { back() })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LibraryScreen(model: MainModel) {
    val library = model.library
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var selecting by remember { mutableStateOf(false) }
    val selection = remember { mutableStateListOf<String>() }
    var openLatest by remember { mutableStateOf(Settings.openLatestOnLaunch) }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        Settings.askedPhotoPermission = true
        library.refreshAccess()
        scope.launch {
            library.reload()
            model.openLatest(onlyIfNew = false)
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(20)) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            val keys = uris.map { ItemStore.keyFor(it) }.filter { model.store.item(it) != null }
            if (keys.isNotEmpty()) {
                selecting = false
                model.routes += ReviewRoute(keys)
            }
        }
    }
    fun pickManually() = picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    fun openSettings() = context.startActivity(
        Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
    )
    LaunchedEffect(library.filter, library.access) { library.reload() }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(if (selecting) "已选 ${selection.size} 张" else "截图打码") },
            navigationIcon = {
                if (library.isAuthorized) {
                    TextButton(onClick = {
                        selecting = !selecting
                        selection.clear()
                    }) { Text(if (selecting) "取消" else "多选") }
                }
            },
            actions = {
                var menu by remember { mutableStateOf(false) }
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, "更多") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text("打开 App 时进入最新图片") },
                        leadingIcon = { Checkbox(checked = openLatest, onCheckedChange = null) },
                        onClick = {
                            openLatest = !openLatest
                            Settings.openLatestOnLaunch = openLatest
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("用系统选择器选图") }, leadingIcon = { Icon(Icons.Outlined.PhotoLibrary, null) },
                        onClick = { menu = false; pickManually() },
                    )
                    if (library.access == PhotoLibrary.Access.PARTIAL) {
                        DropdownMenuItem(
                            text = { Text("选择更多可访问的照片") }, leadingIcon = { Icon(Icons.Outlined.AddCircleOutline, null) },
                            onClick = { menu = false; permission.launch(PhotoLibrary.permissions) },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("照片访问权限设置") }, leadingIcon = { Icon(Icons.Outlined.Settings, null) },
                        onClick = { menu = false; openSettings() },
                    )
                }
            },
        )

        when (library.access) {
            PhotoLibrary.Access.NONE -> PermissionPrompt(
                denied = Settings.askedPhotoPermission,
                onRequest = { permission.launch(PhotoLibrary.permissions) },
                onOpenSettings = ::openSettings,
                onPickManually = ::pickManually,
            )
            else -> {
                if (library.access == PhotoLibrary.Access.PARTIAL) {
                    Row(
                        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).padding(horizontal = 16.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.Lock, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.width(8.dp))
                        Text("只能看到你允许的照片", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                        TextButton(onClick = { permission.launch(PhotoLibrary.permissions) }) { Text("选择更多") }
                    }
                }
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                    PhotoLibrary.Filter.entries.forEachIndexed { i, f ->
                        SegmentedButton(
                            selected = library.filter == f, onClick = { library.filter = f },
                            shape = SegmentedButtonDefaults.itemShape(i, PhotoLibrary.Filter.entries.size),
                        ) { Text(f.label) }
                    }
                }
                Box(Modifier.weight(1f)) {
                    PhotoGrid(library, selection) { asset ->
                        if (selecting) {
                            if (asset.key in selection) selection.remove(asset.key) else if (selection.size < 20) selection += asset.key
                        } else {
                            model.routes += ReviewRoute(listOf(asset.key))
                        }
                    }
                    if (library.assets.isEmpty()) {
                        EmptyState(
                            Icons.Outlined.Photo,
                            if (library.access == PhotoLibrary.Access.PARTIAL) "还没有允许访问的照片" else "相册里还没有图片",
                            if (library.filter == PhotoLibrary.Filter.SCREENSHOTS) "截一张图后回到这里。" else "",
                            Modifier.align(Alignment.Center),
                        )
                    }
                }
                if (selecting) {
                    Button(
                        onClick = {
                            val keys = selection.toList()
                            selecting = false
                            selection.clear()
                            model.routes += ReviewRoute(keys)
                        },
                        enabled = selection.isNotEmpty(),
                        modifier = Modifier.fillMaxWidth().padding(16.dp).height(48.dp),
                    ) { Text("打码 ${selection.size} 张") }
                }
            }
        }
    }
}

/** 还没授权 / 被拒绝时显示的说明页 */
@Composable
private fun PermissionPrompt(denied: Boolean, onRequest: () -> Unit, onOpenSettings: () -> Unit, onPickManually: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            if (denied) Icons.Outlined.ErrorOutline else Icons.Outlined.VisibilityOff, null, Modifier.size(64.dp),
            tint = if (denied) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary,
        )
        Text(if (denied) "没有相册访问权限" else "自动找出截图里的敏感信息", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Text(
            if (denied) "开启后，打开 App 会直接进入最新的截图。\n也可以不开启，每次手动选择图片。"
            else "允许访问相册后，打开 App 会直接进入最新的截图并开始识别。\n可以允许全部照片，或只允许部分照片。\n图片只在本机处理，不会上传。",
            textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (denied) {
            Button(onClick = onRequest) { Text("再次请求权限") }
            OutlinedButton(onClick = onOpenSettings) { Text("去设置开启") }
        } else {
            Button(onClick = onRequest) { Text("允许访问相册") }
        }
        TextButton(onClick = onPickManually) { Text("手动选择图片") }
    }
}

@Composable
private fun EmptyState(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String, modifier: Modifier = Modifier) {
    Column(modifier.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(12.dp))
        Text(title, style = MaterialTheme.typography.titleMedium)
        if (detail.isNotEmpty()) Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** 三列照片网格 */
@Composable
private fun PhotoGrid(library: PhotoLibrary, selection: List<String>, onTap: (PhotoLibrary.Asset) -> Unit) {
    val px = with(LocalDensity.current) { 140.dp.roundToPx() }
    LazyVerticalGrid(
        columns = GridCells.Fixed(3),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(library.assets, key = { it.id }) { asset ->
            val image by produceState<ImageBitmap?>(null, asset.id) { value = library.thumbnail(asset, px) }
            val index = selection.indexOf(asset.key)
            Box(
                Modifier.aspectRatio(1f).background(MaterialTheme.colorScheme.surfaceContainerHigh)
                    .then(if (index >= 0) Modifier.border(3.dp, MaterialTheme.colorScheme.primary) else Modifier)
                    .clickable(onClickLabel = if (asset.isOutput) "已打码" else null) { onTap(asset) },
            ) {
                image?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
                if (asset.isOutput) {
                    Text(
                        "已打码", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.align(Alignment.BottomStart).padding(4.dp)
                            .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(50)).padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
                if (index >= 0) {
                    Box(
                        Modifier.align(Alignment.TopEnd).padding(4.dp).size(22.dp).background(MaterialTheme.colorScheme.primary, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) { Text("${index + 1}", color = MaterialTheme.colorScheme.onPrimary, fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                }
            }
        }
    }
}

/** 读取图片（可能要从云端取回）后显示编辑页；识别由编辑页自己开始 */
@Composable
fun ReviewContainer(key: String, store: ItemStore, onBack: (() -> Unit)?, onSaved: ((SaveReport) -> Unit)? = null) {
    val state by produceState<Pair<RedactItem?, Boolean>>(store.cached(key) to false, key) {
        if (value.first == null) value = store.item(key) to true
    }
    val (item, loaded) = state
    when {
        item != null -> ReviewScreen(item, onBack, onSaved)
        loaded -> Column(Modifier.fillMaxSize()) {
            if (onBack != null) TextButton(onClick = onBack, modifier = Modifier.padding(8.dp)) { Text("返回") }
            EmptyState(Icons.Outlined.ErrorOutline, "无法读取这张图片", "图片可能已被删除，或还在从云端下载。", Modifier.fillMaxWidth().weight(1f))
        }
        else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    }
}

/** 批量：顶部缩略图条切换，当前这张由编辑页负责识别，其余的在后台依次识别 */
@Composable
fun BatchReview(keys: List<String>, store: ItemStore, onBack: () -> Unit) {
    var current by remember(keys) { mutableStateOf(keys.first()) }
    var exportItems by remember { mutableStateOf<List<RedactItem>?>(null) }
    var report by remember { mutableStateOf<SaveReport?>(null) }
    val scope = rememberCoroutineScope()
    val trash = rememberTrashLauncher()
    val listState = rememberLazyListState()

    LaunchedEffect(keys) {
        for (key in keys) store.item(key)?.detectIfNeeded()
    }
    LaunchedEffect(current) { listState.animateScrollToItem(keys.indexOf(current).coerceAtLeast(0)) }

    /** ✓ 保存了当前这张：跳到下一张还没保存的；全部保存完就提示 */
    fun savedCurrent(result: SaveReport) {
        if (result.outcome != SaveReport.Outcome.SUCCESS) {
            report = result
            return
        }
        val unsaved = keys.filter { store.cached(it)?.phase != RedactItem.Phase.Saved }
        val next = unsaved.firstOrNull { keys.indexOf(it) > keys.indexOf(current) } ?: unsaved.firstOrNull()
        if (next != null) current = next else report = SaveReport("${keys.size} 张都已保存", SaveReport.Outcome.SUCCESS)
    }

    Column(Modifier.fillMaxSize()) {
        Surface(color = MaterialTheme.colorScheme.surfaceContainer, shadowElevation = 2.dp) {
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                LazyRow(
                    state = listState, modifier = Modifier.weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp),
                ) {
                    items(keys, key = { it }) { key -> BatchThumb(key, store, key == current) { current = key } }
                }
                TextButton(onClick = {
                    scope.launch { exportItems = keys.mapNotNull { store.item(it) } }
                }, modifier = Modifier.padding(end = 8.dp)) { Text("全部导出") }
            }
        }
        Box(Modifier.weight(1f)) {
            androidx.compose.runtime.key(current) {
                ReviewContainer(current, store, onBack = onBack, onSaved = ::savedCurrent)
            }
        }
    }
    exportItems?.let { items ->
        ExportSheet(items, trash, onDismiss = { exportItems = null }, onSaved = { report = it })
    }
    report?.let { ReportDialog(it) { report = null } }
}

@Composable
private fun BatchThumb(key: String, store: ItemStore, isCurrent: Boolean, onClick: () -> Unit) {
    val item by produceState(store.cached(key), key) { if (value == null) value = store.item(key) }
    Box(
        Modifier.size(40.dp, 56.dp).clip(RoundedCornerShape(5.dp))
            .border(2.dp, if (isCurrent) MaterialTheme.colorScheme.primary else Color.Transparent, RoundedCornerShape(5.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .clickable(onClick = onClick),
    ) {
        item?.thumbnail?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        Box(Modifier.align(Alignment.BottomEnd).padding(2.dp)) {
            when (item?.phase) {
                RedactItem.Phase.Saved -> Icon(Icons.Filled.CheckCircle, "已保存", Modifier.size(14.dp).background(Color.White, CircleShape), tint = SaveGreen)
                is RedactItem.Phase.Failed -> Icon(Icons.Filled.Error, "识别失败", Modifier.size(14.dp).background(Color.White, CircleShape), tint = Color.Red)
                RedactItem.Phase.Ready -> Unit
                else -> CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp)
            }
        }
    }
}
