package io.github.wkj2333666.android_ssh_codex

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.PowerManager

/** Observe network/power changes without pinging or changing connection policy. */
class ConnectionDiagnostics(context: Context) {
    private val app = context.applicationContext
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)
    private var networkRegistered = false
    private var powerRegistered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = logNetwork("network.available", network)
        override fun onLost(network: Network) = logNetwork("network.lost", network)
        override fun onLosing(network: Network, maxMsToLive: Int) =
            logNetwork("network.losing", network, mapOf("maxMsToLive" to maxMsToLive))
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
            logNetwork("network.capabilities", network, capabilities(caps))
        override fun onBlockedStatusChanged(network: Network, blocked: Boolean) =
            logNetwork("network.blocked", network, mapOf("blocked" to blocked))
    }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val reason = when (intent.action) {
                PowerManager.ACTION_POWER_SAVE_MODE_CHANGED -> "power_save_changed"
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> "device_idle_changed"
                ConnectivityManager.ACTION_RESTRICT_BACKGROUND_CHANGED -> "data_saver_changed"
                else -> "unknown"
            }
            DiagnosticLog.record(app, "policy.changed", snapshot() + ("change" to reason))
        }
    }

    fun start() {
        try {
            connectivity.registerDefaultNetworkCallback(callback)
            networkRegistered = true
        } catch (error: Exception) {
            DiagnosticLog.record(app, "network.observerFailed", mapOf("errorType" to error.javaClass.simpleName))
        }
        try {
            val filter = IntentFilter().apply {
                addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                addAction(ConnectivityManager.ACTION_RESTRICT_BACKGROUND_CHANGED)
            }
            if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else app.registerReceiver(receiver, filter)
            powerRegistered = true
        } catch (error: Exception) {
            DiagnosticLog.record(app, "policy.observerFailed", mapOf("errorType" to error.javaClass.simpleName))
        }
        DiagnosticLog.record(app, "network.snapshot", snapshot())
    }

    fun stop() {
        if (networkRegistered) try { connectivity.unregisterNetworkCallback(callback) } catch (_: Exception) {}
        if (powerRegistered) try { app.unregisterReceiver(receiver) } catch (_: Exception) {}
        networkRegistered = false
        powerRegistered = false
    }

    fun snapshot(): Map<String, Any?> = try {
        val network = connectivity.activeNetwork
        val power = app.getSystemService(PowerManager::class.java)
        mapOf(
            "activeNetwork" to network?.networkHandle,
            "networkPresent" to (network != null),
            "metered" to connectivity.isActiveNetworkMetered,
            "dataSaverStatus" to connectivity.restrictBackgroundStatus,
            "powerSave" to power.isPowerSaveMode,
            "deviceIdle" to power.isDeviceIdleMode,
            "interactive" to power.isInteractive,
            "batteryExempt" to power.isIgnoringBatteryOptimizations(app.packageName),
            "serviceActive" to ConnectionService.active
        ) + capabilities(network?.let { connectivity.getNetworkCapabilities(it) })
    } catch (error: Exception) { mapOf("snapshotErrorType" to error.javaClass.simpleName) }

    private fun logNetwork(event: String, network: Network, fields: Map<String, Any?> = emptyMap()) {
        DiagnosticLog.record(app, event, fields + ("network" to network.networkHandle))
    }

    private fun capabilities(caps: NetworkCapabilities?): Map<String, Any?> = mapOf(
        "validated" to caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
        "internet" to caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
        "wifi" to caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
        "cellular" to caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
        "vpn" to caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
        "ethernet" to caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    )
}
