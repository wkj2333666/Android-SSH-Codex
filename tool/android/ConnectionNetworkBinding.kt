package io.github.wkj2333666.android_ssh_codex

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import java.util.concurrent.ConcurrentHashMap

/**
 * Keeps the process' SSH/RPC sockets on a requested, validated network while
 * the user-visible connection service is active. This covers both chat and
 * file transfer because both run in the same application process.
 */
class ConnectionNetworkBinding(context: Context) {
    private val app = context.applicationContext
    private val connectivity =
        app.getSystemService(ConnectivityManager::class.java)
    private val available = ConcurrentHashMap<Network, NetworkCapabilities>()
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var started = false

    fun start() {
        if (started) return
        started = true
        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
                .build()
            val next = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    val caps = connectivity.getNetworkCapabilities(network)
                    if (caps != null) {
                        available[network] = caps
                        rebind(network)
                    }
                    DiagnosticLog.record(app, "service.networkAvailable",
                        mapOf("network" to network.networkHandle))
                }

                override fun onCapabilitiesChanged(
                    network: Network,
                    caps: NetworkCapabilities,
                ) {
                    available[network] = caps
                    rebind(network)
                }

                override fun onLost(network: Network) {
                    available.remove(network)
                    rebind(null)
                    DiagnosticLog.record(app, "service.networkLost",
                        mapOf("network" to network.networkHandle))
                }

                override fun onBlockedStatusChanged(
                    network: Network,
                    blocked: Boolean,
                ) {
                    val caps = connectivity.getNetworkCapabilities(network)
                    if (caps != null) available[network] = caps
                    rebind(network)
                }
            }
            callback = next
            connectivity.requestNetwork(request, next)
        } catch (error: Exception) {
            DiagnosticLog.record(app, "service.networkRequestFailed",
                mapOf("errorType" to error.javaClass.simpleName))
        }
        try {
            val manager = app.getSystemService(WifiManager::class.java)
            wifiLock = manager.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "${app.packageName}:SSHConnection",
            ).also {
                it.setReferenceCounted(false)
                it.acquire()
            }
        } catch (error: Exception) {
            DiagnosticLog.record(app, "service.wifiLockFailed",
                mapOf("errorType" to error.javaClass.simpleName))
        }
        rebind(null)
        DiagnosticLog.record(app, "service.networkBindingStarted")
    }

    fun stop() {
        if (!started) return
        started = false
        callback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        callback = null
        available.clear()
        try {
            connectivity.bindProcessToNetwork(null)
        } catch (_: Exception) {
        }
        wifiLock?.let {
            try {
                if (it.isHeld) it.release()
            } catch (_: Exception) {
            }
        }
        wifiLock = null
        DiagnosticLog.record(app, "service.networkBindingStopped")
    }

    private fun rebind(changed: Network?) {
        if (!started) return
        val active = connectivity.activeNetwork
        val preferred = when {
            active != null && usable(available[active]) -> active
            changed != null && usable(available[changed]) -> changed
            else -> available.entries.firstOrNull { usable(it.value) }?.key
        }
        try {
            connectivity.bindProcessToNetwork(preferred)
            DiagnosticLog.record(app, "service.networkBound",
                mapOf("network" to preferred?.networkHandle))
        } catch (error: Exception) {
            DiagnosticLog.record(app, "service.networkBindFailed",
                mapOf("errorType" to error.javaClass.simpleName))
        }
    }

    private fun usable(caps: NetworkCapabilities?): Boolean =
        caps != null &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
}
