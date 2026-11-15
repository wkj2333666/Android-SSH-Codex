package io.github.wkj2333666.android_ssh_codex

import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.roundToInt

/** The isolated UID has no access to the app cache, SSH data, or network.
 * Each request grants access only to the PDF and its output file via FDs.
 */
class PdfPageService : Service() {
    private val worker = HandlerThread("pdf-render").apply { start() }
    private val messenger = Messenger(Handler(worker.looper) { request ->
        val response = Message.obtain()
        try {
            response.arg1 = render(request.data, request.arg1)
        } catch (_: SecurityException) {
            response.data = Bundle().apply {
                putString("error", "This PDF is encrypted or password-protected.")
            }
        } catch (_: Exception) {
            response.data = Bundle().apply { putString("error", "Could not render this PDF.") }
        }
        try { request.replyTo?.send(response) } catch (_: Exception) { /* Caller closed. */ }
        true
    })

    override fun onBind(intent: Intent): IBinder = messenger.binder

    override fun onDestroy() {
        worker.quitSafely()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun render(data: Bundle, index: Int): Int {
        val output = requireNotNull(data.getParcelable<ParcelFileDescriptor>("output"))
        ParcelFileDescriptor.AutoCloseOutputStream(output).use { stream ->
            val input = requireNotNull(data.getParcelable<ParcelFileDescriptor>("input"))
            val renderer = try {
                PdfRenderer(input)
            } catch (error: Exception) {
                input.close()
                throw error
            }
            renderer.use {
                val count = renderer.pageCount
                require(index in 0 until count)
                renderer.openPage(index).use { page ->
                    val scale = minOf(3f, 1800f / maxOf(page.width, page.height))
                    val width = (page.width * scale).roundToInt().coerceAtLeast(1)
                    val height = (page.height * scale).roundToInt().coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        val matrix = Matrix().apply { setScale(scale, scale) }
                        page.render(bitmap, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
                    } finally {
                        bitmap.recycle()
                    }
                }
                return count
            }
        }
    }
}

/** One bounded request at a time; unbinding also releases the isolated service. */
class PdfPageClient(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var pending: Request? = null

    fun render(path: String, page: Int, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("BUSY", "A PDF page is already loading.", null)
            return
        }
        val file = try {
            val input = File(path).canonicalFile
            val parent = requireNotNull(input.parentFile)
            require(page >= 0 && input.name == "payload.bin" &&
                parent.name.startsWith("codex-download-") &&
                parent.parentFile == context.cacheDir.canonicalFile &&
                input.isFile && input.length() in 1L..(64L * 1024L * 1024L))
            input
        } catch (_: Exception) {
            result.error("BAD_PDF_FILE", "PDF preview file is unavailable.", null)
            return
        }
        val request = Request(file, page, result)
        pending = request
        request.start()
    }

    fun close() { pending?.finish(error = "PDF preview closed.") }

    private inner class Request(
        private val file: File,
        private val page: Int,
        private val result: MethodChannel.Result,
    ) : ServiceConnection {
        private var bound = false
        private val deadline = Runnable { finish(error = "PDF page took too long to render.") }
        private val response = Messenger(Handler(Looper.getMainLooper()) { message ->
            val error = message.data.getString("error")
            if (error == null && message.arg1 > page) finish(count = message.arg1)
            else finish(error = error ?: "Invalid PDF page.")
            true
        })

        fun start() {
            try {
                bound = context.bindService(Intent(context, PdfPageService::class.java), this, Context.BIND_AUTO_CREATE)
                if (bound) main.postDelayed(deadline, 20000)
                else finish(error = "PDF renderer is unavailable.")
            } catch (_: Exception) {
                finish(error = "PDF renderer is unavailable.")
            }
        }

        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            if (pending !== this) return
            try {
                val outputFile = File(file.parentFile, "pdf-page.png")
                val flags = ParcelFileDescriptor.MODE_CREATE or
                    ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_WRITE_ONLY
                ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { input ->
                    ParcelFileDescriptor.open(outputFile, flags).use { output ->
                        Messenger(service).send(Message.obtain().apply {
                            arg1 = page
                            replyTo = response
                            data = Bundle().apply {
                                putParcelable("input", input)
                                putParcelable("output", output)
                            }
                        })
                    }
                }
            } catch (_: Exception) {
                finish(error = "Could not start PDF rendering.")
            }
        }

        override fun onServiceDisconnected(name: ComponentName) =
            finish(error = "The PDF renderer stopped.")

        override fun onBindingDied(name: ComponentName) = onServiceDisconnected(name)
        override fun onNullBinding(name: ComponentName) = onServiceDisconnected(name)

        fun finish(count: Int? = null, error: String? = null) {
            if (pending !== this) return
            pending = null
            main.removeCallbacks(deadline)
            if (bound) context.unbindService(this)
            if (error == null) result.success(count) else result.error("PDF_RENDER", error, null)
        }
    }
}
