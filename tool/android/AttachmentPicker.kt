package io.github.wkj2333666.android_ssh_codex

import android.app.Activity
import android.content.Intent
import android.graphics.BitmapFactory
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class AttachmentPicker(private val activity: Activity) {
    companion object {
        private const val MAX_ATTACHMENT_BYTES = 1024L * 1024L * 1024L
    }

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
            var target: File? = null
            try {
                val resolver = activity.contentResolver
                var name = "attachment"
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                val directory = File(activity.cacheDir, "codex-attachments")
                require(directory.isDirectory || directory.mkdirs()) { "Cannot create attachment cache" }
                val outputFile = File.createTempFile("picked-", ".bin", directory)
                target = outputFile
                var size = 0L
                resolver.openInputStream(uri)?.use { input ->
                    outputFile.outputStream().use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            size += count
                            require(size <= MAX_ATTACHMENT_BYTES) { "File exceeds 1 GiB" }
                            output.write(buffer, 0, count)
                        }
                    }
                } ?: throw IllegalStateException("Cannot read selected file")
                val header = ByteArray(12)
                val headerSize = outputFile.inputStream().use { it.read(header) }
                fun bytesAt(offset: Int, vararg expected: Int): Boolean =
                    headerSize >= offset + expected.size && expected.indices.all {
                        (header[offset + it].toInt() and 255) == expected[it]
                    }
                val image = bytesAt(0, 255, 216, 255) ||
                    bytesAt(0, 137, 80, 78, 71, 13, 10, 26, 10) ||
                    (bytesAt(0, 82, 73, 70, 70) && bytesAt(8, 87, 69, 66, 80)) ||
                    bytesAt(0, 71, 73, 70, 56, 55, 97) ||
                    bytesAt(0, 71, 73, 70, 56, 57, 97)
                require(!requireImage || image) { "Choose a PNG, JPEG, WebP or GIF image" }
                if (image) {
                    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(outputFile.absolutePath, options)
                    require(options.outWidth in 1..16384 && options.outHeight in 1..16384 &&
                        options.outWidth.toLong() * options.outHeight <= 64_000_000L) {
                        "Image is invalid or exceeds 64 megapixels"
                    }
                }
                activity.runOnUiThread {
                    if (pending !== result) {
                        outputFile.delete()
                        return@runOnUiThread
                    }
                    pending = null
                    result.success(mapOf(
                        "name" to name.take(200),
                        "path" to outputFile.absolutePath,
                        "size" to size,
                        "isImage" to image))
                }
            } catch (error: Exception) {
                target?.delete()
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
