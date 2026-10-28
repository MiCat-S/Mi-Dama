// 相册写入：Android 10+ 往公共相册写自己的文件不需要任何权限；
// "保存后删除原图"用系统的移到回收站请求（Android 11+），系统会先请用户确认
package com.example.redact.data

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** 保存结果：弹窗文案 + 结果类型 */
data class SaveReport(val message: String, val outcome: Outcome) {
    enum class Outcome {
        /** 全部保存成功（包括用户自己在系统确认框里取消了删除原图） */
        SUCCESS,

        /** 图片已保存，但有部分没完成（中途出错、原图没删掉） */
        PARTIAL,
        FAILURE,
    }
}

object PhotoSaver {
    private const val ALBUM = "截图打码"

    suspend fun save(context: Context, data: ByteArray, filename: String, mimeType: String): Uri = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, filename)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/$ALBUM")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
            ?: error("无法写入相册")
        try {
            resolver.openOutputStream(uri)?.use { it.write(data) } ?: error("无法写入相册")
            resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        uri
    }

    /**
     * 逐张导出并保存；全部成功后（可选）一次性把原图移到回收站
     * @param trash 弹出系统的确认框，返回用户是否同意
     */
    suspend fun saveAll(
        context: Context,
        items: List<RedactItem>,
        deletingOriginals: Boolean,
        trash: suspend (IntentSender) -> Boolean,
        progress: (Int) -> Unit = {},
    ): SaveReport {
        val settings = Settings.export
        var saved = 0
        val originals = mutableListOf<RedactItem>()
        var withoutOriginal = 0
        try {
            for (item in items) {
                item.detectIfNeeded()
                val job = item.export(settings)
                save(context, job.encode(), job.outputFilename, job.format.mimeType)
                item.phase = RedactItem.Phase.Saved
                saved++
                progress(saved)
                if (item.mediaUri != null) originals += item else withoutOriginal++
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            Settings.markProcessed(originals.mapNotNull { it.mediaId })
            val reason = e.message ?: e.javaClass.simpleName
            return if (saved > 0) SaveReport("已保存 $saved 张，之后出错：$reason", SaveReport.Outcome.PARTIAL)
            else SaveReport(reason, SaveReport.Outcome.FAILURE)
        }
        Settings.markProcessed(originals.mapNotNull { it.mediaId })

        val head = if (saved == 1) "已保存到相册" else "已保存 $saved 张到相册"
        var text = head
        var outcome = SaveReport.Outcome.SUCCESS
        if (deletingOriginals && originals.isNotEmpty()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val request = MediaStore.createTrashRequest(context.contentResolver, originals.mapNotNull { it.mediaUri }, true)
                text = if (trash(request.intentSender)) "$head，原图已移到回收站" else "$head，原图未删除"
            } else {
                text = "$head。Android 10 不支持移到回收站，原图未删除"
                outcome = SaveReport.Outcome.PARTIAL
            }
        }
        if (deletingOriginals && withoutOriginal > 0) text += "（$withoutOriginal 张不是从相册打开的，原图未删除）"
        return SaveReport(text, outcome)
    }

    /** 渲染到缓存目录，生成分享用的 Intent（经 FileProvider 只授权读这几个文件） */
    suspend fun shareIntent(context: Context, items: List<RedactItem>): Intent {
        val dir = File(context.cacheDir, "shared").apply {
            deleteRecursively()
            mkdirs()
        }
        val uris = ArrayList<Uri>()
        val types = mutableSetOf<String>()
        for (item in items) {
            item.detectIfNeeded()
            val job = item.export(Settings.export)
            val file = File(dir, job.outputFilename)
            val data = job.encode()
            withContext(Dispatchers.IO) { file.writeBytes(data) }
            uris += FileProvider.getUriForFile(context, "${context.packageName}.files", file)
            types += job.format.mimeType
        }
        val send = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }
        send.type = types.singleOrNull() ?: "image/*"
        send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return Intent.createChooser(send, if (items.size == 1) "分享打码后的图片" else "分享 ${items.size} 张打码后的图片")
    }
}
