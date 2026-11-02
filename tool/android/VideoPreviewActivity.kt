package io.github.wkj2333666.android_ssh_codex

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Build
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.MediaController
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.VideoView
import android.widget.Toast
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** App-private local playback only. Never expose SSH credentials or a local
 * HTTP media server, and never accept arbitrary external file/HTTP URIs.
 */
class VideoPreviewActivity : Activity() {
    companion object {
        const val REQUEST = 4105

        fun previewFile(context: Context, path: String): File {
            val file = File(path).canonicalFile
            val parent = file.parentFile
            val downloaded = file.name == "payload.bin" &&
                parent?.name?.startsWith("codex-download-") == true &&
                parent?.parentFile == context.cacheDir.canonicalFile
            val selected = parent == File(context.filesDir, "codex-attachments").canonicalFile &&
                file.name.startsWith("picked-")
            require((downloaded || selected) && file.isFile &&
                file.length() in 1L..(1024L * 1024L * 1024L)) {
                "Video cache is unavailable. Open the video again."
            }
            return file
        }
    }

    private var video: VideoView? = null
    private var controls: MediaController? = null
    private var prepared = false
    private var resumePlayback = true
    private var position = 0
    private var foreground = false
    private var downloads: AttachmentDownloads? = null
    private var saveButton: Button? = null
    private var saving = false
    private var closeAfterSave = false
    private var destroyed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val file = try {
            previewFile(this, intent.getStringExtra("path") ?: "")
        } catch (_: Exception) {
            setResult(RESULT_CANCELED, Intent().putExtra("error", "Video cache is unavailable. Open the video again."))
            finish()
            return
        }
        position = savedInstanceState?.getInt("position") ?: 0
        resumePlayback = savedInstanceState?.getBoolean("playing", true) ?: true
        setResult(RESULT_OK)
        downloads = AttachmentDownloads(this)
        val name = (intent.getStringExtra("name") ?: "Video").take(200)
        window.statusBarColor = Color.BLACK
        window.navigationBarColor = Color.BLACK
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        root.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            } else {
                @Suppress("DEPRECATION")
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            }
            insets
        }
        val player = object : VideoView(this) {
            override fun start() { super.start(); keepScreenOn = true }
            override fun pause() { super.pause(); keepScreenOn = false }
        }
        video = player
        root.addView(player, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        val loading = ProgressBar(this)
        root.addView(loading, FrameLayout.LayoutParams(96, 96, Gravity.CENTER))
        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(0xAA000000.toInt())
        }
        val title = TextView(this).apply {
            text = name
            setTextColor(Color.WHITE)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(16, 8, 16, 8)
        }
        toolbar.addView(title, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val save = Button(this).apply {
            text = "Save"
            setOnClickListener { saveVideo(file, name) }
        }
        saveButton = save
        toolbar.addView(save)
        toolbar.addView(Button(this).apply {
            text = "Close"
            setOnClickListener { finish() }
        })
        root.addView(toolbar, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP))
        val mediaControls = MediaController(this)
        controls = mediaControls
        mediaControls.setAnchorView(root)
        player.setMediaController(mediaControls)
        player.setOnPreparedListener {
            prepared = true
            loading.visibility = View.GONE
            if (position > 0) player.seekTo(position)
            if (foreground && resumePlayback) player.start()
            mediaControls.show(3000)
        }
        player.setOnCompletionListener {
            resumePlayback = false
            player.keepScreenOn = false
            mediaControls.show(0)
        }
        player.setOnErrorListener { _, what, extra ->
            prepared = false
            player.keepScreenOn = false
            loading.visibility = View.GONE
            val message = "This device cannot play the video format. Tap Save to keep the original file."
            DiagnosticLog.record(this, "video.playbackError", mapOf("what" to what, "extra" to extra))
            setResult(RESULT_CANCELED, Intent().putExtra("error", message))
            root.addView(TextView(this).apply {
                text = message
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
                setPadding(32, 32, 32, 32)
            }, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
            true
        }
        setContentView(root)
        root.requestApplyInsets()
        player.setVideoPath(file.absolutePath)
        player.requestFocus()
    }

    private fun saveVideo(file: File, name: String) {
        val exporter = downloads ?: return
        if (saving || destroyed) return
        saving = true
        saveButton?.isEnabled = false
        saveButton?.text = "Saving…"
        // Export the current private file; do not open another SSH download.
        exporter.saveVideo(file.absolutePath, name, object : MethodChannel.Result {
            override fun success(value: Any?) {
                completeSave(if (value == true) "Video saved" else "Save cancelled")
            }
            override fun error(code: String, message: String?, details: Any?) {
                completeSave("Could not save video ($code). Try another location.")
            }
            override fun notImplemented() { completeSave("Video saving is unavailable") }
        })
    }

    private fun completeSave(message: String) {
        saving = false
        if (destroyed) return
        saveButton?.isEnabled = true
        saveButton?.text = "Save"
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        if (closeAfterSave) finish()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == AttachmentDownloads.REQUEST) downloads?.onResult(resultCode, data)
    }

    override fun finish() {
        if (saving && !destroyed) {
            // MainActivity/Dart own the cached file until this player returns.
            // A back/Close action must not release it while the copier needs it.
            closeAfterSave = true
            Toast.makeText(this, "Will close after saving", Toast.LENGTH_SHORT).show()
            return
        }
        super.finish()
    }

    override fun onPause() {
        foreground = false
        video?.let {
            if (prepared) {
                position = it.currentPosition
                resumePlayback = it.isPlaying
                it.pause()
            }
        }
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        foreground = true
        if (prepared && resumePlayback) video?.start()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putInt("position", if (prepared && foreground) video?.currentPosition ?: position else position)
        outState.putBoolean("playing", if (prepared && foreground) video?.isPlaying ?: resumePlayback else resumePlayback)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        destroyed = true
        downloads?.close()
        downloads = null
        controls?.hide()
        video?.stopPlayback()
        video = null
        super.onDestroy()
    }
}
