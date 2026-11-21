package io.github.wkj2333666.android_ssh_codex

import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.util.Locale
import java.util.concurrent.Executors

/** Shared storage I/O uses the application, never a FlutterActivity or picker. */
object PublicDownloads {
    private const val FOLDER = "RemoteCodex"
    private const val LIMIT = 1024L * 1024L * 1024L
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun install(app: Context, messenger: BinaryMessenger) {
        io.execute {
            // In-memory SSH operations cannot survive a process stop.
            // Only remove previous-process staging files, before serving this engine.
            app.cacheDir.listFiles()
                ?.filter { it.name.startsWith("codex-download-") && it.isDirectory }
                ?.forEach { directory ->
                    runCatching {
                        if (directory.canonicalFile == directory.absoluteFile) {
                            File(directory, "payload.bin").delete()
                            directory.delete()
                        }
                    }
                }
        }
        MethodChannel(messenger, "android_ssh_codex/downloads").setMethodCallHandler { call, result ->
            when (call.method) {
                "stagingDirectory" -> io.execute { main.post { result.success(app.cacheDir.absolutePath) } }
                "publish" -> publish(app, call.argument<String>("path").orEmpty(),
                    call.argument<String>("name").orEmpty()) { saved ->
                    saved.fold(onSuccess = { result.success(it) },
                        onFailure = { result.error("SAVE_FAILED",
                            "Could not save to Downloads/RemoteCodex. Check storage space and permissions.", null) })
                }
                "openFile" -> try {
                    openFile(app, Uri.parse(call.argument<String>("uri").orEmpty()))
                    result.success(null)
                } catch (_: Exception) {
                    result.error("OPEN_FAILED",
                        "Could not open the file. Look in Downloads/RemoteCodex.", null)
                }
                "openFolder" -> try {
                    openFolder(app)
                    result.success(null)
                } catch (_: Exception) {
                    result.error("OPEN_FAILED",
                        "Open Downloads/RemoteCodex in your file manager.", null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun publish(context: Context, path: String, name: String,
                finished: (Result<Map<String, String>>) -> Unit) {
        val app = context.applicationContext
        io.execute {
            val saved = try {
                val source = File(path).canonicalFile
                val parent = source.parentFile
                require(source.isFile && source.name == "payload.bin" &&
                    parent?.name?.startsWith("codex-download-") == true &&
                    parent.parentFile == app.cacheDir.canonicalFile && source.length() <= LIMIT)
                val displayName = safeName(name)
                val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(
                    displayName.substringAfterLast('.', "").lowercase(Locale.ROOT))
                    ?: "application/octet-stream"
                Result.success(if (Build.VERSION.SDK_INT >= 29) {
                    publishMediaStore(app, source, displayName, mime)
                } else {
                    publishLegacy(app, source, displayName, mime)
                })
            } catch (error: Exception) {
                DiagnosticLog.record(app, "file.publishFailed",
                    mapOf("exceptionType" to error.javaClass.simpleName))
                Result.failure(error)
            }
            main.post { finished(saved) }
        }
    }

    private fun safeName(name: String): String {
        val cleaned = name.replace(Regex("""[\\/:*?"<>|\p{Cntrl}]"""), "_")
            .trim().trimStart('.').ifBlank { "download" }
        if (cleaned.length <= 80) return cleaned
        val extension = cleaned.substringAfterLast('.', "")
            .takeIf { it.length in 1..16 && !it.any(Char::isWhitespace) }
            ?.let { ".$it" }.orEmpty()
        return cleaned.take(80 - extension.length) + extension
    }

    @android.annotation.TargetApi(29)
    private fun publishMediaStore(app: Context, source: File, name: String,
                                  mime: String): Map<String, String> {
        val resolver = app.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER/")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
            ?: throw IOException("Cannot allocate Downloads row")
        try {
            val output = resolver.openOutputStream(uri, "w")
                ?: throw IOException("No output stream")
            output.use { stream -> source.inputStream().use { it.copyTo(stream, 256 * 1024) } }
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            if (resolver.update(uri, done, null, null) != 1) throw IOException("Cannot publish")
        } catch (error: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
        val actualName = runCatching {
            resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull()
        return mapOf("name" to (actualName ?: name), "uri" to uri.toString())
    }

    @Suppress("DEPRECATION")
    private fun publishLegacy(app: Context, source: File, name: String,
                              mime: String): Map<String, String> {
        val folder = File(Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS), FOLDER)
        if (!folder.isDirectory && !folder.mkdirs()) throw IOException("Cannot create download folder")
        val temp = File.createTempFile(".remote-codex-", ".part", folder)
        try {
            temp.outputStream().use { stream -> source.inputStream().use { it.copyTo(stream, 256 * 1024) } }
            for (index in 0..999) {
                val dot = name.lastIndexOf('.')
                val stem = if (dot > 0) name.substring(0, dot) else name
                val extension = if (dot > 0) name.substring(dot) else ""
                val target = File(folder, if (index == 0) name else "$stem ($index)$extension")
                try {
                    Files.move(temp.toPath(), target.toPath())
                } catch (_: FileAlreadyExistsException) {
                    continue
                }
                val saved = mutableMapOf("name" to target.name)
                runCatching {
                    val manager = app.getSystemService(DownloadManager::class.java)
                    val id = manager.addCompletedDownload(target.name, FOLDER,
                        false, mime, target.absolutePath, target.length(), false)
                    manager.getUriForDownloadedFile(id)?.let { saved["uri"] = it.toString() }
                }
                return saved
            }
            throw IOException("Cannot allocate a unique download name")
        } finally {
            temp.delete()
        }
    }

    private fun openFile(app: Context, uri: Uri) {
        require(uri.scheme == "content" && when (uri.authority) {
            "media" -> uri.pathSegments.getOrNull(1) == "downloads"
            "downloads" -> Build.VERSION.SDK_INT < 29
            else -> false
        })
        // Detect files moved/deleted in the system file manager before launching a viewer.
        val resolver = app.contentResolver
        resolver.openFileDescriptor(uri, "r")?.close() ?: throw IOException("File unavailable")
        app.startActivity(Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, resolver.getType(uri) ?: "application/octet-stream")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun openFolder(app: Context) {
        val folder = DocumentsContract.buildDocumentUri("com.android.externalstorage.documents",
            "primary:${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(folder, DocumentsContract.Document.MIME_TYPE_DIR)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (runCatching { app.startActivity(view) }.isSuccess) return
        val picker = Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*")
            .addCategory(Intent.CATEGORY_OPENABLE)
            .putExtra(DocumentsContract.EXTRA_INITIAL_URI, folder)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (runCatching { app.startActivity(picker) }.isSuccess) return
        app.startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
