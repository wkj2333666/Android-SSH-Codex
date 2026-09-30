package io.github.wkj2333666.android_ssh_codex

import android.content.Context
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** App-private, bounded, ordered I/O; never write on the UI thread. */
object DiagnosticLog {
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS,
        LinkedBlockingQueue<Runnable>(256), ThreadPoolExecutor.AbortPolicy())
    private const val LIMIT = 512 * 1024L

    fun submit(action: () -> Unit): Boolean = try {
        worker.execute { action() }
        true
    } catch (_: java.util.concurrent.RejectedExecutionException) { false }

    fun record(context: Context, event: String, fields: Map<String, Any?> = emptyMap()) {
        val app = context.applicationContext
        val entry = JSONObject(fields).put("event", event)
            .put("nativeTimeMs", System.currentTimeMillis())
            .put("elapsedMs", SystemClock.elapsedRealtime()).put("pid", Process.myPid())
        submit {
            try {
                val current = File(app.noBackupFilesDir, "connection-diagnostics.jsonl")
                val previous = File(app.noBackupFilesDir, "connection-diagnostics.previous.jsonl")
                if (current.length() >= LIMIT) {
                    if (previous.exists() && !previous.delete()) return@submit
                    if (!current.renameTo(previous)) return@submit
                }
                val line = entry.toString()
                if (line.length <= 4096) current.appendText(line + "\n")
            } catch (_: Exception) { /* Best effort; never fail the connection. */ }
        }
    }

    // Call on worker, after earlier log writes, to freeze export before opening picker.
    fun snapshot(context: Context): String = buildString {
        for (name in listOf("connection-diagnostics.previous.jsonl", "connection-diagnostics.jsonl")) {
            val file = File(context.noBackupFilesDir, name)
            if (file.exists()) append(file.readText())
        }
    }
}
