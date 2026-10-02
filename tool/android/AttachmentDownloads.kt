package io.github.wkj2333666.android_ssh_codex

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class AttachmentDownloads(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var source: File? = null
    private val worker = Executors.newSingleThreadExecutor()

    fun save(path: String, name: String, result: MethodChannel.Result) {
        if (pending != null) { result.error("BUSY", "Another save is open", null); return }
        try {
            val file = File(path).canonicalFile
            require(file.name == "payload.bin" && file.parentFile?.name?.startsWith("codex-download-") == true &&
                file.parentFile?.parentFile == activity.cacheDir.canonicalFile && file.isFile && file.length() <= 100 * 1024 * 1024L)
            source = file
            pending = result
            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream")
                .putExtra(Intent.EXTRA_TITLE, name.take(200)), 4104)
        } catch (_: Exception) {
            pending = null
            source = null
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
            } catch (_: Exception) { /* Report failure without exposing file contents. */ }
            activity.runOnUiThread {
                if (pending !== result) return@runOnUiThread
                pending = null; source = null
                if (success) result.success(true) else result.error("SAVE_FAILED", "Cannot save file", null)
            }
        }
    }

    fun close() {
        pending?.error("ACTIVITY_CLOSED", "Save picker closed", null)
        pending = null; source = null
        worker.shutdownNow()
    }
}
