package io.github.wkj2333666.android_ssh_codex

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One application-context engine, shared by the service and any UI host.
 * Activity destruction must never dispose its Dart sockets or controller.
 * Process death still requires a new connection; this is not a resurrection API.
 */
object ConnectionRuntime {
    private var engine: FlutterEngine? = null
    private var diagnostics: ConnectionDiagnostics? = null

    fun obtain(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        val created = FlutterEngine(app)
        engine = created
        val events = MethodChannel(created.dartExecutor.binaryMessenger,
            "android_ssh_codex/connection_events")
        diagnostics = ConnectionDiagnostics(app) { fields ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                events.invokeMethod("networkChanged", fields)
            }
        }.also { it.start() }
        events.setMethodCallHandler { call, result ->
            if (call.method == "snapshot") result.success(diagnostics?.snapshot())
            else result.notImplemented()
        }
        installDetachedHandlers(app, created)
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        DiagnosticLog.record(app, "runtime.created")
        return created
    }

    fun observer(): ConnectionDiagnostics? = diagnostics

    /** Replace UI closures so no destroyed Activity is retained by the engine. */
    fun installDetachedHandlers(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "android_ssh_codex/connection_service")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            app.startForegroundService(Intent(app, ConnectionService::class.java))
                            result.success(app.getSystemService(NotificationManager::class.java).areNotificationsEnabled())
                        }
                        "stop" -> {
                            app.stopService(Intent(app, ConnectionService::class.java))
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("KEEP_ALIVE_FAILED", error.message, null)
                }
            }
        MethodChannel(messenger, "android_ssh_codex/diagnostics")
            .setMethodCallHandler { call, result ->
                if (call.method == "record") {
                    val fields = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    DiagnosticLog.record(app, fields["event"] as? String ?: "unknown",
                        fields.entries.associate { it.key.toString() to it.value } +
                            (diagnostics?.snapshot() ?: emptyMap()))
                    result.success(null)
                } else result.error("ACTIVITY_CLOSED", "Open the app to export diagnostics", null)
            }
        MethodChannel(messenger, "android_ssh_codex/attachments")
            .setMethodCallHandler { call, result ->
                if (call.method == "downloadDirectory") result.success(app.cacheDir.absolutePath)
                else result.error("ACTIVITY_CLOSED", "Open the app to select or save files", null)
            }
    }
}
