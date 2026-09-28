package io.github.wkj2333666.android_ssh_codex

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4101) {
            permissionResult?.success(getSystemService(NotificationManager::class.java).areNotificationsEnabled())
            permissionResult = null
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // This service protects this engine's sockets; never leave an orphan.
        stopService(Intent(this, ConnectionService::class.java))
        permissionResult?.error("ACTIVITY_CLOSED", "Connection activity closed", null)
        permissionResult = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
