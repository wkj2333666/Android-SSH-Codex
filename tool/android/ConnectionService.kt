package io.github.wkj2333666.android_ssh_codex

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class ConnectionService : Service() {
    companion object {
        var active: Boolean = false
            private set
    }
    private var wakeLock: PowerManager.WakeLock? = null

    @SuppressLint("WakelockTimeout") // Lifetime is bounded by the visible connection service.
    override fun onCreate() {
        super.onCreate()
        DiagnosticLog.record(this, "service.create")
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            "ssh_connection", "SSH connection", NotificationManager.IMPORTANCE_LOW
        ))
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, "ssh_connection")
            .setSmallIcon(R.drawable.ic_connection)
            .setContentTitle("Codex connection active")
            .setContentText("Keeping SSH available in background. Open app to disconnect.")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(4100, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(4100, notification)
        }
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:SSHConnection")
            .also { it.setReferenceCounted(false); it.acquire() }
        active = true
        DiagnosticLog.record(this, "service.foreground", mapOf("wakeLockHeld" to wakeLock?.isHeld))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val power = getSystemService(PowerManager::class.java)
        DiagnosticLog.record(this, "service.start", mapOf(
            "wakeLockHeld" to wakeLock?.isHeld, "deviceIdle" to power.isDeviceIdleMode,
            "powerSave" to power.isPowerSaveMode,
            "batteryExempt" to power.isIgnoringBatteryOptimizations(packageName)))
        return START_NOT_STICKY
    }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        DiagnosticLog.record(this, "service.taskRemoved")
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        active = false
        DiagnosticLog.record(this, "service.destroy", mapOf("wakeLockHeld" to wakeLock?.isHeld))
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
