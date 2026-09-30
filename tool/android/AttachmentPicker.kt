package io.github.wkj2333666.android_ssh_codex

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class AttachmentPicker(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var imageOnly = false
    private val worker = Executors.newSingleThreadExecutor()

    fun pick(image: Boolean, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("BUSY", "A file picker is already open", null)
            return
        }
        pending = result
        imageOnly = image
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType(if (image) "image/*" else "*/*"), 4103)
        } catch (_: Exception) {
            pending = null
            result.error("PICK_FAILED", "Cannot open file picker", null)
        }
    }

    fun onResult(resultCode: Int, data: Intent?) {
        val result = pending ?: return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending = null
            result.success(null)
            return
        }
        val requireImage = imageOnly
        worker.execute {
            try {
                val resolver = activity.contentResolver
                var name = "attachment"
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                val bytes = resolver.openInputStream(uri)?.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(65536)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(output.size() + count <= 10 * 1024 * 1024) { "File exceeds 10 MiB" }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                } ?: throw IllegalStateException("Cannot read selected file")
                val header = bytes.take(12).map { it.toInt() and 255 }
                val image = (header.size >= 3 && header.take(3) == listOf(255, 216, 255)) ||
                    (header.size >= 8 && header.take(8) == listOf(137, 80, 78, 71, 13, 10, 26, 10)) ||
                    (bytes.size >= 12 && String(bytes, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                        String(bytes, 8, 4, Charsets.US_ASCII) == "WEBP") ||
                    (bytes.size >= 6 && String(bytes, 0, 6, Charsets.US_ASCII) in listOf("GIF87a", "GIF89a"))
                require(!requireImage || image) { "Choose a PNG, JPEG, WebP or GIF image" }
                if (image) {
                    val options = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                    require(options.outWidth > 0 && options.outHeight > 0 &&
                        options.outWidth.toLong() * options.outHeight <= 64_000_000L) {
                        "Image is invalid or exceeds 64 megapixels"
                    }
                }
                activity.runOnUiThread {
                    if (pending !== result) return@runOnUiThread
                    pending = null
                    result.success(mapOf("name" to name.take(200), "bytes" to bytes, "isImage" to image))
                }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    if (pending !== result) return@runOnUiThread
                    pending = null
                    result.error("READ_FAILED", if (error is IllegalArgumentException) error.message else "Cannot read selected file", null)
                }
            }
        }
    }

    fun close() {
        pending?.error("ACTIVITY_CLOSED", "File picker closed", null)
        pending = null
        worker.shutdownNow()
    }
}
