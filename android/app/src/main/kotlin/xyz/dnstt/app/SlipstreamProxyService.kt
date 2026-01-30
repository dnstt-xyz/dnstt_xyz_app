package xyz.dnstt.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground service for running Slipstream proxy mode.
 * Slipstream provides a high-performance covert channel over DNS (QUIC-over-DNS).
 * This service executes the native slipstream binary and manages its lifecycle.
 */
class SlipstreamProxyService : Service() {

    companion object {
        const val TAG = "SlipstreamProxyService"
        const val NOTIFICATION_CHANNEL_ID = "slipstream_proxy_channel"
        const val NOTIFICATION_ID = 3

        const val ACTION_CONNECT = "xyz.dnstt.app.SLIPSTREAM_CONNECT"
        const val ACTION_DISCONNECT = "xyz.dnstt.app.SLIPSTREAM_DISCONNECT"

        const val EXTRA_DNS_SERVER = "dns_server"
        const val EXTRA_TUNNEL_DOMAIN = "tunnel_domain"
        const val EXTRA_PROXY_PORT = "proxy_port"
        const val EXTRA_AUTHORITATIVE = "authoritative"

        var isRunning = AtomicBoolean(false)
        var stateCallback: ((String) -> Unit)? = null
    }

    private var dnsServer: String = "8.8.8.8"
    private var tunnelDomain: String = ""
    private var proxyPort: Int = 7000
    private var authoritative: Boolean = false

    private var slipstreamProcess: Process? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var logThread: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_CONNECT -> {
                dnsServer = intent.getStringExtra(EXTRA_DNS_SERVER) ?: "8.8.8.8"
                tunnelDomain = intent.getStringExtra(EXTRA_TUNNEL_DOMAIN) ?: ""
                proxyPort = intent.getIntExtra(EXTRA_PROXY_PORT, 7000)
                authoritative = intent.getBooleanExtra(EXTRA_AUTHORITATIVE, false)
                Thread { connect() }.start()
                START_STICKY
            }
            ACTION_DISCONNECT -> {
                disconnect()
                START_NOT_STICKY
            }
            else -> START_NOT_STICKY
        }
    }

    private fun connect() {
        if (isRunning.get()) {
            Log.d(TAG, "Slipstream already running")
            return
        }

        try {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("slipstream_connecting")
            }

            createNotificationChannel()
            startForeground(NOTIFICATION_ID, createNotification("connecting"))

            acquireWakeLock()

            if (!startSlipstreamProcess()) {
                Log.e(TAG, "Failed to start Slipstream process")
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    stateCallback?.invoke("slipstream_error")
                }
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            isRunning.set(true)
            updateNotification("connected")

            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("slipstream_connected")
            }

            Log.d(TAG, "Slipstream service started successfully")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Slipstream service", e)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("slipstream_error")
            }
            disconnect()
        }
    }

    private fun startSlipstreamProcess(): Boolean {
        if (tunnelDomain.isEmpty()) {
            Log.e(TAG, "Tunnel domain not provided")
            return false
        }

        try {
            stopSlipstreamProcess()

            if (isPortInUse(proxyPort)) {
                Log.w(TAG, "Port $proxyPort in use, waiting...")
                waitForPortRelease(proxyPort)
                if (isPortInUse(proxyPort)) {
                    Log.e(TAG, "Port $proxyPort still in use after waiting")
                    return false
                }
            }

            val binaryPath = applicationInfo.nativeLibraryDir + "/libslipstream.so"
            val binary = File(binaryPath)
            if (!binary.exists()) {
                Log.e(TAG, "Slipstream binary not found at $binaryPath")
                return false
            }

            Log.d(TAG, "Starting Slipstream process")
            Log.d(TAG, "Binary: $binaryPath")
            Log.d(TAG, "Domain: $tunnelDomain, DNS: $dnsServer, Port: $proxyPort")

            val cmdList = mutableListOf(
                binaryPath,
                "--domain", tunnelDomain,
                "--tcp-listen-host", "127.0.0.1",
                "--tcp-listen-port", proxyPort.toString()
            )

            if (authoritative) {
                cmdList.add("--authoritative")
                cmdList.add(dnsServer)
            } else {
                cmdList.add("--resolver")
                cmdList.add(dnsServer)
            }

            Log.i(TAG, "=== Starting Slipstream Connection ===")
            Log.i(TAG, "Command: ${cmdList.joinToString(" ")}")
            Log.i(TAG, "Tunnel Domain: $tunnelDomain")
            Log.i(TAG, "DNS Resolver: $dnsServer")
            Log.i(TAG, "Local Port: $proxyPort")
            Log.i(TAG, "Authoritative Mode: $authoritative")

            val processBuilder = ProcessBuilder(cmdList)
            processBuilder.redirectErrorStream(true)
            processBuilder.environment()["RUST_LOG"] = "info"

            slipstreamProcess = processBuilder.start()

            // Start log reader thread
            logThread = Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(slipstreamProcess!!.inputStream))
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        // Use info level for important slipstream output
                        Log.i(TAG, "[slipstream] $line")
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "Log reader stopped: ${e.message}")
                }
            }
            logThread?.start()

            // Wait briefly and check if process is still alive
            Thread.sleep(500)

            val alive = slipstreamProcess?.isAlive ?: false
            if (alive) {
                Log.i(TAG, "=== Slipstream Process Started Successfully ===")
                Log.i(TAG, "Proxy listening on 127.0.0.1:$proxyPort")
            } else {
                val exitCode = slipstreamProcess?.exitValue() ?: -1
                Log.e(TAG, "=== Slipstream Process Failed ===")
                Log.e(TAG, "Exit code: $exitCode")
                return false
            }

            return true

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Slipstream process", e)
            return false
        }
    }

    private fun stopSlipstreamProcess() {
        slipstreamProcess?.let { process ->
            try {
                process.destroy()
                Thread.sleep(200)
                if (process.isAlive) {
                    process.destroyForcibly()
                }
                Log.d(TAG, "Slipstream process stopped")
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping Slipstream process", e)
            }
        }
        slipstreamProcess = null

        logThread?.interrupt()
        logThread = null
    }

    private fun isPortInUse(port: Int): Boolean {
        return try {
            val socket = java.net.ServerSocket(port)
            socket.close()
            false
        } catch (e: Exception) {
            true
        }
    }

    private fun waitForPortRelease(port: Int, maxWaitMs: Int = 3000) {
        val startTime = System.currentTimeMillis()
        while (isPortInUse(port) && (System.currentTimeMillis() - startTime) < maxWaitMs) {
            Log.d(TAG, "Waiting for port $port...")
            Thread.sleep(200)
        }
    }

    private fun disconnect() {
        Log.i(TAG, "=== Disconnecting Slipstream Service ===")

        stateCallback?.invoke("slipstream_disconnecting")

        stopSlipstreamProcess()
        releaseWakeLock()

        isRunning.set(false)
        stateCallback?.invoke("slipstream_disconnected")

        stopForeground(STOP_FOREGROUND_REMOVE)

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager?.cancel(NOTIFICATION_ID)

        stopSelf()
        Log.i(TAG, "=== Slipstream Service Disconnected ===")
    }

    override fun onDestroy() {
        disconnect()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Slipstream Proxy Connection",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows when Slipstream proxy is connected"
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            enableVibration(false)
            setSound(null, null)
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(channel)
    }

    private fun createNotification(state: String): Notification {
        val openAppIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val disconnectIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, SlipstreamProxyService::class.java).apply {
                action = ACTION_DISCONNECT
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val (title, text, icon) = when (state) {
            "connecting" -> Triple(
                "Slipstream Connecting...",
                "Establishing QUIC-over-DNS tunnel via $dnsServer",
                android.R.drawable.ic_popup_sync
            )
            "connected" -> Triple(
                "Slipstream Connected",
                "TCP proxy on port $proxyPort",
                android.R.drawable.ic_lock_lock
            )
            else -> Triple(
                "Slipstream Proxy",
                "Status: $state",
                android.R.drawable.ic_lock_lock
            )
        }

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(icon)
            .setContentIntent(openAppIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .setSilent(true)

        if (state == "connected") {
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Disconnect",
                disconnectIntent
            )
        }

        return builder.build()
    }

    private fun updateNotification(state: String) {
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, createNotification(state))
    }

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "SlipstreamProxyService::WakeLock"
            )
        }
        wakeLock?.let {
            if (!it.isHeld) {
                it.acquire()
                Log.d(TAG, "Wake lock acquired")
            }
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
                Log.d(TAG, "Wake lock released")
            }
        }
        wakeLock = null
    }
}
