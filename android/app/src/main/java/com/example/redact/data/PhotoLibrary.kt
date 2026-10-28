// 读取相册：权限（全部 / 部分照片 / 拒绝）、按时间倒序列出图片、缩略图、找出"最新一张待打码"
package com.example.redact.data

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.LruCache
import android.util.Size
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class PhotoLibrary(context: Context) {
    private val context = context.applicationContext

    enum class Access { NONE, PARTIAL, FULL }

    enum class Filter(val label: String) { ALL("全部"), SCREENSHOTS("截图") }

    data class Asset(val id: Long, val uri: Uri, val name: String) {
        /** 本 App 导出的图（文件名带 -redacted.） */
        val isOutput get() = name.lowercase().contains(RedactItem.FILENAME_MARKER)
        val key get() = keyFor(id)
    }

    var access by mutableStateOf(currentAccess())
        private set
    var filter by mutableStateOf(Filter.ALL)
    var assets by mutableStateOf<List<Asset>>(emptyList())
        private set

    val isAuthorized get() = access != Access.NONE

    private val thumbnails = object : LruCache<Long, ImageBitmap>(32 * 1024 * 1024) {
        override fun sizeOf(key: Long, value: ImageBitmap) = value.width * value.height * 4
    }

    /** 从「设置」回来、或在系统弹窗里改了授权后调用 */
    fun refreshAccess() {
        access = currentAccess()
        if (!isAuthorized) assets = emptyList()
    }

    private fun currentAccess(): Access {
        fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && granted(Manifest.permission.READ_MEDIA_IMAGES) -> Access.FULL
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> Access.PARTIAL
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && granted(Manifest.permission.READ_EXTERNAL_STORAGE) -> Access.FULL
            else -> Access.NONE
        }
    }

    suspend fun reload() {
        if (!isAuthorized) return
        assets = query(filter, limit = null)
    }

    private suspend fun query(filter: Filter, limit: Int?): List<Asset> = withContext(Dispatchers.IO) {
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME)
        var selection: String? = null
        var args: Array<String>? = null
        if (filter == Filter.SCREENSHOTS) {
            // 各家系统的截图目录名不一样：Screenshots / 截屏 / 截图
            val keys = listOf("%Screenshot%", "%截屏%", "%截图%")
            selection = keys.joinToString(" OR ") {
                "${MediaStore.Images.Media.RELATIVE_PATH} LIKE ? OR ${MediaStore.Images.Media.BUCKET_DISPLAY_NAME} LIKE ?"
            }
            args = keys.flatMap { listOf(it, it) }.toTypedArray()
        }
        val order = "${MediaStore.Images.Media.DATE_ADDED} DESC, ${MediaStore.Images.Media._ID} DESC"
        val out = mutableListOf<Asset>()
        runCatching {
            context.contentResolver.query(collection, projection, selection, args, order)?.use { c ->
                while (c.moveToNext() && (limit == null || out.size < limit)) {
                    val id = c.getLong(0)
                    out += Asset(id, ContentUris.withAppendedId(collection, id), c.getString(1).orEmpty())
                }
            }
        }
        out
    }

    /** 最新的一张"待打码"图片：跳过本 App 导出的图和已经保存过打码版本的原图 */
    suspend fun latestUnprocessed(): Asset? {
        if (!isAuthorized) return null
        val processed = Settings.processed
        return query(Filter.ALL, limit = 30).firstOrNull { !it.isOutput && it.id !in processed }
    }

    suspend fun thumbnail(asset: Asset, side: Int): ImageBitmap? {
        thumbnails.get(asset.id)?.let { return it }
        val image = withContext(Dispatchers.IO) {
            runCatching { context.contentResolver.loadThumbnail(asset.uri, Size(side, side), null).asImageBitmap() }.getOrNull()
        } ?: return null
        thumbnails.put(asset.id, image)
        return image
    }

    private var observer: ContentObserver? = null

    /** 相册有变化（新截图、删除）时回调 */
    fun observe(onChange: () -> Unit) {
        if (observer != null) return
        observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) = onChange()
        }.also { context.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, it) }
    }

    fun stopObserving() {
        observer?.let { context.contentResolver.unregisterContentObserver(it) }
        observer = null
    }

    companion object {
        /** 申请的权限：14+ 同时带上"部分照片"，系统弹窗里就会有「选择照片」 */
        val permissions: Array<String>
            get() = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
                    arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
                else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            }

        fun keyFor(mediaId: Long) = "media:$mediaId"
    }
}

/**
 * 已打开过的图片（识别结果、勾选、样式）在本次运行内保留，来回切换不用重新识别。
 * key：相册图片用 "media:<id>"，系统选择器 / 分享进来的图用 "uri:<uri>"
 */
class ItemStore(context: Context) {
    private val context = context.applicationContext

    /** 按访问顺序排列，超出容量时丢掉最久没用的（每张只留压缩后的原图数据和识别结果） */
    private val items = object : LinkedHashMap<String, RedactItem>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, RedactItem>) = size > 40
    }

    fun cached(key: String): RedactItem? = items[key]

    fun register(item: RedactItem) {
        items[item.key] = item
    }

    suspend fun item(key: String): RedactItem? {
        items[key]?.let { return it }
        val item = when {
            key.startsWith("media:") -> {
                val id = key.removePrefix("media:").toLongOrNull() ?: return null
                RedactItem.load(context, key, ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id), id)
            }
            key.startsWith("uri:") -> RedactItem.load(context, key, Uri.parse(key.removePrefix("uri:")))
            else -> null
        } ?: return null
        // 加载期间另一处已经放进来了：用先到的那份
        return items.getOrPut(key) { item }
    }

    companion object {
        fun keyFor(uri: Uri) = "uri:$uri"
    }
}
