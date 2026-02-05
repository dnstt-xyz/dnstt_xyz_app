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
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground service for running Slipstream proxy mode.
 * Same pattern as DnsttProxyService but uses SlipstreamBridge.
 */
class SlipstreamProxyService : Service() {

    companion object {
        const val TAG = "SlipstreamProxy"
        const val NOTIFICATION_CHANNEL_ID = "slipstream_proxy_channel"
        const val NOTIFICATION_ID = 3

        const val ACTION_CONNECT = "xyz.dnstt.app.SLIPSTREAM_PROXY_CONNECT"
        const val ACTION_DISCONNECT = "xyz.dnstt.app.SLIPSTREAM_PROXY_DISCONNECT"

        const val EXTRA_DNS_SERVER = "dns_server"
        const val EXTRA_TUNNEL_DOMAIN = "tunnel_domain"
        const val EXTRA_PROXY_PORT = "proxy_port"
        const val EXTRA_CONGESTION_CONTROL = "congestion_control"
        const val EXTRA_KEEP_ALIVE_INTERVAL = "keep_alive_interval"
        const val EXTRA_GSO = "gso"
        const val EXTRA_SHARE_PROXY = "share_proxy"

        var isRunning = AtomicBoolean(false)
        var stateCallback: ((String) -> Unit)? = null
    }

    private var dnsServer: String = "8.8.8.8"
    private var tunnelDomain: String = ""
    private var proxyPort: Int = 7000
    private var congestionControl: String = "dcubic"
    private var keepAliveInterval: Int = 400
    private var gso: Boolean = false
    private var shareProxy: Boolean = false

    // Host for proxy connection verification - always localhost
    private val proxyHost = "127.0.0.1"

    private var slipstreamBridge: SlipstreamBridge? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val isConnecting = AtomicBoolean(false)
    private var connectThread: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_CONNECT -> {
                dnsServer = intent.getStringExtra(EXTRA_DNS_SERVER) ?: "8.8.8.8"
                tunnelDomain = intent.getStringExtra(EXTRA_TUNNEL_DOMAIN) ?: ""
                proxyPort = intent.getIntExtra(EXTRA_PROXY_PORT, 7000)
                congestionControl = intent.getStringExtra(EXTRA_CONGESTION_CONTROL) ?: "dcubic"
                keepAliveInterval = intent.getIntExtra(EXTRA_KEEP_ALIVE_INTERVAL, 400)
                gso = intent.getBooleanExtra(EXTRA_GSO, false)
                shareProxy = intent.getBooleanExtra(EXTRA_SHARE_PROXY, false)
                if (isConnecting.compareAndSet(false, true)) {
                    connectThread = Thread { connect() }
                    connectThread?.start()
                } else {
                    Log.d(TAG, "Connection already in progress, ignoring")
                }
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
            Log.d(TAG, "Slipstream proxy already running")
            isConnecting.set(false)
            return
        }

        try {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("proxy_connecting")
            }

            createNotificationChannel()
            startForeground(NOTIFICATION_ID, createNotification("connecting"))

            acquireWakeLock()

            if (!SlipstreamBridge.isAvailable()) {
                Log.e(TAG, "Slipstream library not available")
                isConnecting.set(false)
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    stateCallback?.invoke("proxy_error")
                }
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            slipstreamBridge = SlipstreamBridge()
            val host = if (shareProxy) "0.0.0.0" else "127.0.0.1"

            val started = slipstreamBridge!!.startClient(
                domain = tunnelDomain,
                dnsServer = dnsServer,
                congestionControl = congestionControl,
                keepAliveInterval = keepAliveInterval,
                port = proxyPort,
                host = host,
                gso = gso
            )

            if (!started) {
                val error = slipstreamBridge?.lastError ?: "Unknown error"
                Log.e(TAG, "Failed to start slipstream client: $error")
                isConnecting.set(false)
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    stateCallback?.invoke("proxy_error")
                }
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            // Wait a moment for proxy to be ready
            Thread.sleep(200)

            // Verify tunnel actually works
            Log.d(TAG, "Verifying tunnel connectivity...")
            if (!verifyTunnelConnection(10000)) {
                Log.e(TAG, "Tunnel verification failed - connection not working")
                isConnecting.set(false)
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    stateCallback?.invoke("proxy_error")
                }
                slipstreamBridge?.stopClient()
                slipstreamBridge = null
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            Log.d(TAG, "Tunnel verification passed")

            isRunning.set(true)
            isConnecting.set(false)

            updateNotification("connected")

            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("proxy_connected")
            }

            Log.d(TAG, "Slipstream proxy service started successfully")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start slipstream proxy service", e)
            isConnecting.set(false)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("proxy_error")
            }
            disconnect()
        }
    }

    /**
     * Verifies the tunnel actually works by making an HTTP request through the SOCKS5 proxy.
     */
    private fun verifyTunnelConnection(timeoutMs: Int = 10000): Boolean {
        return try {
            Log.d(TAG, "Verifying tunnel connection via HTTP request...")

            val socket = java.net.Socket()
            socket.soTimeout = timeoutMs
            socket.connect(java.net.InetSocketAddress(proxyHost, proxyPort), 5000)

            val output = socket.getOutputStream()
            val input = socket.getInputStream()

            // SOCKS5 handshake
            output.write(byteArrayOf(0x05, 0x01, 0x00))
            output.flush()

            val authResponse = ByteArray(2)
            val authRead = input.read(authResponse)
            if (authRead != 2 || authResponse[0] != 0x05.toByte() || authResponse[1] != 0x00.toByte()) {
                socket.close()
                return false
            }

            // Connect to api.ipify.org:80
            val targetHost = "api.ipify.org"
            val targetPort = 80
            val connectRequest = ByteArray(7 + targetHost.length)
            connectRequest[0] = 0x05
            connectRequest[1] = 0x01
            connectRequest[2] = 0x00
            connectRequest[3] = 0x03
            connectRequest[4] = targetHost.length.toByte()
            System.arraycopy(targetHost.toByteArray(), 0, connectRequest, 5, targetHost.length)
            connectRequest[5 + targetHost.length] = ((targetPort shr 8) and 0xFF).toByte()
            connectRequest[6 + targetHost.length] = (targetPort and 0xFF).toByte()

            output.write(connectRequest)
            output.flush()

            val connectResponse = ByteArray(10)
            val responseRead = input.read(connectResponse, 0, 4)
            if (responseRead < 4 || connectResponse[1] != 0x00.toByte()) {
                socket.close()
                return false
            }

            // Read remaining response
            when (connectResponse[3]) {
                0x01.toByte() -> input.read(ByteArray(6))
                0x03.toByte() -> {
                    val domainLen = input.read()
                    input.read(ByteArray(domainLen + 2))
                }
                0x04.toByte() -> input.read(ByteArray(18))
            }

            // Send HTTP request
            val httpRequest = "GET /?format=text HTTP/1.1\r\nHost: $targetHost\r\nConnection: close\r\n\r\n"
            output.write(httpRequest.toByteArray())
            output.flush()

            val responseBuffer = ByteArray(256)
            val bytesRead = input.read(responseBuffer)
            socket.close()

            if (bytesRead > 0) {
                val response = String(responseBuffer, 0, bytesRead)
                if (response.contains("200 OK") || response.contains("200")) {
                    Log.d(TAG, "Tunnel verification SUCCESS")
                    return true
                }
            }

            Log.w(TAG, "Tunnel verification failed")
            false
        } catch (e: Exception) {
            Log.w(TAG, "Tunnel verification error: ${e.message}")
            false
        }
    }

    private fun disconnect() {
        Log.d(TAG, "Disconnecting slipstream proxy service")

        stateCallback?.invoke("proxy_disconnecting")

        slipstreamBridge?.stopClient()
        slipstreamBridge = null
        releaseWakeLock()

        isRunning.set(false)
        isConnecting.set(false)
        stateCallback?.invoke("proxy_disconnected")

        stopForeground(STOP_FOREGROUND_REMOVE)

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager?.cancel(NOTIFICATION_ID)

        stopSelf()
        Log.d(TAG, "Slipstream proxy service disconnected")
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
                "Slipstream Proxy Connecting...",
                "Establishing tunnel via $dnsServer",
                android.R.drawable.ic_popup_sync
            )
            "connected" -> Triple(
                "Slipstream Proxy Connected",
                "SOCKS5 proxy on port $proxyPort",
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
