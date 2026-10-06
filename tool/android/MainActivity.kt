package io.github.wkj2333666.android_ssh_codex

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine =
        ConnectionRuntime.obtain(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    private var permissionResult: MethodChannel.Result? = null
    private var exportResult: MethodChannel.Result? = null
    private var exportSnapshot: String? = null
    private var attachmentPicker: AttachmentPicker? = null
    private var attachmentDownloads: AttachmentDownloads? = null
    private var connectionDiagnostics: ConnectionDiagnostics? = null

    private fun recordLifecycle(event: String) {
        val power = getSystemService(android.os.PowerManager::class.java)
        DiagnosticLog.record(this, event, mapOf(
            "serviceActive" to ConnectionService.active,
            "deviceIdle" to power.isDeviceIdleMode,
            "powerSave" to power.isPowerSaveMode,
            "batteryExempt" to power.isIgnoringBatteryOptimizations(packageName)))
    }

    override fun onResume() {
        super.onResume()
        recordLifecycle("activity.resume")
    }

    override fun onStop() {
        recordLifecycle("activity.stop")
        super.onStop()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        attachmentPicker = AttachmentPicker(this)
        attachmentDownloads = AttachmentDownloads(this)
        connectionDiagnostics = ConnectionRuntime.observer()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "android_ssh_codex/attachments").setMethodCallHandler { call, result ->
            if (call.method == "downloadDirectory") result.success(cacheDir.absolutePath)
            else if (call.method == "saveDownload") {
                val downloads = attachmentDownloads
                if (downloads == null) result.error("ACTIVITY_CLOSED", "Save picker closed", null)
                else downloads.save(call.argument<String>("path") ?: "", call.argument<String>("name") ?: "download", result)
            }
            else if (call.method == "pick") {
                val picker = attachmentPicker
                if (picker == null) result.error("ACTIVITY_CLOSED", "File picker closed", null)
                else picker.pick(call.argument<Boolean>("image") == true, result)
            }
            else result.notImplemented()
        }
        DiagnosticLog.record(this, "engine.configure", mapOf(
            "version" to packageManager.getPackageInfo(packageName, 0).versionName,
            "sdk" to Build.VERSION.SDK_INT))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "android_ssh_codex/diagnostics").setMethodCallHandler { call, result ->
            when (call.method) {
                "record" -> {
                    val fields = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    val event = fields["event"] as? String ?: "unknown"
                    val snapshot = if (event.endsWith(".error") || event.endsWith(".done") || event.endsWith(".timeout") ||
                        event == "connection.transportLoss" || event == "rpc.disconnected")
                        connectionDiagnostics?.snapshot() ?: emptyMap() else emptyMap()
                    DiagnosticLog.record(this, event,
                        fields.entries.associate { it.key.toString() to it.value } + snapshot)
                    result.success(null)
                }
                "export" -> {
                    if (exportResult != null) {
                        result.error("BUSY", "An export is already open", null)
                    } else {
                        exportResult = result
                        val accepted = DiagnosticLog.submit {
                            try {
                                val snapshot = DiagnosticLog.snapshot(applicationContext)
                                runOnUiThread {
                                    if (exportResult !== result) return@runOnUiThread
                                    exportSnapshot = snapshot
                                    try {
                                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT)
                                            .addCategory(Intent.CATEGORY_OPENABLE)
                                            .setType("text/plain")
                                            .putExtra(Intent.EXTRA_TITLE, "codex-connection-diagnostics.txt"), 4102)
                                    } catch (_: Exception) { finishExport(false, "Cannot open document picker") }
                                }
                            } catch (_: Exception) {
                                runOnUiThread { finishExport(false, "Cannot read diagnostics") }
                            }
                        }
                        if (!accepted) finishExport(false, "Diagnostics queue is busy")
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "android_ssh_codex/connection_service").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        startForegroundService(Intent(this, ConnectionService::class.java))
                        val preferences = getSharedPreferences("connection_service", MODE_PRIVATE)
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                            !preferences.getBoolean("notification_requested", false)) {
                            preferences.edit().putBoolean("notification_requested", true).apply()
                            permissionResult = result
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4101)
                        } else {
                            result.success(getSystemService(NotificationManager::class.java).areNotificationsEnabled())
                        }
                    } catch (error: Exception) {
                        stopService(Intent(this, ConnectionService::class.java))
                        result.error("KEEP_ALIVE_FAILED", error.message, null)
                    }
                }
                "stop" -> {
                    stopService(Intent(this, ConnectionService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun finishExport(saved: Boolean, error: String? = null) {
        if (error == null) exportResult?.success(saved)
        else exportResult?.error("EXPORT_FAILED", error, null)
        exportResult = null
        exportSnapshot = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 4104) {
            attachmentDownloads?.onResult(resultCode, data)
            return
        }
        if (requestCode == 4103) {
            attachmentPicker?.onResult(resultCode, data)
            return
        }
        if (requestCode != 4102) return
        val uri = data?.data
        val snapshot = exportSnapshot
        if (resultCode != Activity.RESULT_OK || uri == null || snapshot == null) {
            finishExport(false)
            return
        }
        if (!DiagnosticLog.submit {
            try {
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw java.io.IOException("No output stream")
                stream.use { it.write(snapshot.toByteArray(Charsets.UTF_8)) }
                runOnUiThread { finishExport(true) }
            } catch (_: Exception) {
                runOnUiThread { finishExport(false, "Cannot save diagnostics") }
            }
        }) finishExport(false, "Diagnostics queue is busy")
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4101) {
            permissionResult?.success(getSystemService(NotificationManager::class.java).areNotificationsEnabled())
            permissionResult = null
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        DiagnosticLog.record(this, "engine.cleanup")
        connectionDiagnostics = null
        attachmentPicker?.close()
        attachmentDownloads?.close()
        attachmentDownloads = null
        attachmentPicker = null
        finishExport(false, "Connection activity closed")
        ConnectionRuntime.installDetachedHandlers(applicationContext, flutterEngine)
        permissionResult?.error("ACTIVITY_CLOSED", "Connection activity closed", null)
        permissionResult = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
