package io.github.wkj2333666.android_ssh_codex

import android.app.Activity
import android.content.Intent
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.Locale

class AttachmentDownloads(private val activity: Activity) {
    companion object { const val REQUEST = 4104 }
    private var pending: MethodChannel.Result? = null
    private var source: File? = null
    private val worker = Executors.newSingleThreadExecutor()

    fun save(path: String, name: String, result: MethodChannel.Result) {
        beginSave(path, name, result, video = false)
    }

    fun saveVideo(path: String, name: String, result: MethodChannel.Result) {
        beginSave(path, name, result, video = true)
    }

    private fun beginSave(path: String, name: String, result: MethodChannel.Result, video: Boolean) {
        if (pending != null) { result.error("BUSY", "Another save is open", null); return }
        try {
            val file = if (video) VideoPreviewActivity.previewFile(activity, path) else {
                val cached = File(path).canonicalFile
                require(cached.name == "payload.bin" && cached.parentFile?.name?.startsWith("codex-download-") == true &&
                    cached.parentFile?.parentFile == activity.cacheDir.canonicalFile && cached.isFile &&
                    cached.length() <= 1024L * 1024L * 1024L)
                cached
            }
            val mime = if (video) {
                MimeTypeMap.getSingleton().getMimeTypeFromExtension(
                    name.substringAfterLast('.', "").lowercase(Locale.ROOT))
                    ?.takeIf { it.startsWith("video/") } ?: "application/octet-stream"
            } else "application/octet-stream"
            source = file
            pending = result
            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE).setType(mime)
                .putExtra(Intent.EXTRA_TITLE, name.take(200)), REQUEST)
        } catch (error: Exception) {
            pending = null
            source = null
            logFailure("picker", error)
            result.error("SAVE_FAILED", "Cannot open save picker", null)
        }
    }

    fun onResult(code: Int, data: Intent?) {
        val result = pending ?: return
        val file = source ?: return
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) {
            pending = null; source = null; result.success(false); return
        }
        worker.execute {
            var success = false
            try {
                val output = activity.contentResolver.openOutputStream(uri, "wt")
                    ?: throw java.io.IOException("No output stream")
                output.use {
                    file.inputStream().use { it.copyTo(output, 65536) }
                }
                success = true
            } catch (error: Exception) { logFailure("copy", error) }
            activity.runOnUiThread {
                if (pending !== result) return@runOnUiThread
                pending = null; source = null
                if (success) result.success(true) else result.error("SAVE_FAILED", "Cannot save file", null)
            }
        }
    }

    private fun logFailure(stage: String, error: Exception) {
        DiagnosticLog.record(activity, "file.saveFailed", mapOf(
            "stage" to stage, "exceptionType" to error.javaClass.simpleName,
            "causeType" to error.cause?.javaClass?.simpleName))
    }

    fun close() {
        pending?.error("ACTIVITY_CLOSED", "Save picker closed", null)
        pending = null; source = null
        worker.shutdownNow()
    }
}
