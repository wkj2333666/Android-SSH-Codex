package io.github.wkj2333666.android_ssh_codex

import android.app.Activity
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/** Only selected/private cached files, one decoder, small JPEG response. */
class VideoThumbnails(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private val pending = mutableSetOf<MethodChannel.Result>()
    private var closed = false

    fun load(path: String, result: MethodChannel.Result) {
        if (closed || pending.size >= 4) {
            result.error("PREVIEW_BUSY", "Video cover unavailable", null)
            return
        }
        val file = try { VideoPreviewActivity.previewFile(activity, path) }
            catch (_: Exception) { result.error("PREVIEW_UNAVAILABLE", "Video cache unavailable", null); return }
        pending.add(result)
        worker.execute {
            val retriever = MediaMetadataRetriever()
            var frame: Bitmap? = null
            var scaled: Bitmap? = null
            var bytes: ByteArray? = null
            try {
                retriever.setDataSource(file.absolutePath)
                val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                require(width in 1..8192 && height in 1..8192 && width.toLong() * height <= 32_000_000L)
                frame = if (Build.VERSION.SDK_INT >= 27)
                    retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 640, 360)
                else {
                    require(width.toLong() * height <= 16_000_000L)
                    retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                }
                val original = frame ?: throw IllegalStateException("No cover")
                val scale = minOf(1.0, 640.0 / original.width, 360.0 / original.height)
                val bitmap = if (scale < 1) Bitmap.createScaledBitmap(original,
                    maxOf(1, (original.width * scale).toInt()), maxOf(1, (original.height * scale).toInt()), true)
                    else original
                scaled = bitmap
                val output = ByteArrayOutputStream()
                require(bitmap.compress(Bitmap.CompressFormat.JPEG, 80, output))
                require(output.size() <= 512 * 1024)
                bytes = output.toByteArray()
            } catch (_: Exception) { /* No file contents or paths in errors. */ }
            finally {
                if (scaled !== frame) scaled?.recycle()
                frame?.recycle()
                try { retriever.release() } catch (_: Exception) {}
            }
            val response = bytes
            activity.runOnUiThread {
                if (!pending.remove(result)) return@runOnUiThread
                if (response == null) result.error("PREVIEW_UNAVAILABLE", "Video cover unavailable", null)
                else result.success(response)
            }
        }
    }

    fun close() {
        closed = true
        pending.forEach { it.error("ACTIVITY_CLOSED", "Video cover closed", null) }
        pending.clear()
        worker.shutdownNow()
    }
}
