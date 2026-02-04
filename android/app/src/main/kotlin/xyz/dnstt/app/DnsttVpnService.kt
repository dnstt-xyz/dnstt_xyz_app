package xyz.dnstt.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import mobile.Mobile

class DnsttVpnService : VpnService() {

    companion object {
        const val TAG = "DnsttVpnService"
        const val NOTIFICATION_CHANNEL_ID = "dnstt_vpn_channel_v2"
        const val NOTIFICATION_ID = 1

        const val ACTION_CONNECT = "xyz.dnstt.app.CONNECT"
        const val ACTION_DISCONNECT = "xyz.dnstt.app.DISCONNECT"

        const val EXTRA_PROXY_HOST = "proxy_host"
        const val EXTRA_PROXY_PORT = "proxy_port"
        const val EXTRA_DNS_SERVER = "dns_server"
        const val EXTRA_TUNNEL_DOMAIN = "tunnel_domain"
        const val EXTRA_PUBLIC_KEY = "public_key"
        const val EXTRA_SSH_MODE = "ssh_mode"
        const val EXTRA_SOCKS_USERNAME = "socks_username"
        const val EXTRA_SOCKS_PASSWORD = "socks_password"

        var isRunning = AtomicBoolean(false)
        var stateCallback: ((String) -> Unit)? = null
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var proxyHost: String = "127.0.0.1"
    private var proxyPort: Int = 7000
    private var dnsServer: String = "8.8.8.8"
    private var tunnelDomain: String = ""
    private var publicKey: String = ""
    private var isSshMode: Boolean = false
    private var socksUsername: String? = null
    private var socksPassword: String? = null

    private var runningThread: Thread? = null
    private val shouldRun = AtomicBoolean(false)

    // Wake lock to prevent CPU from sleeping
    private var wakeLock: PowerManager.WakeLock? = null

    private val tcpConnections = ConcurrentHashMap<String, TcpConnection>()

    // Go-based dnstt client from gomobile library
    private var dnsttClient: mobile.DnsttClient? = null

    // Thread pool for TCP SYN handshakes (async so VPN loop isn't blocked)
    private var tcpExecutor: ExecutorService? = null

    // Thread pool for DNS queries with a small bounded queue.
    // Excess DNS queries are dropped — Android will retry them.
    private var dnsExecutor: ExecutorService? = null

    // Pool of persistent SOCKS5 connections for DNS-over-TCP queries
    private val dnsConnPool = ConcurrentLinkedDeque<DnsTunnelConnection>()
    private val DNS_POOL_MAX = 4
    private val DNS_CONN_IDLE_MS = 30_000L

    /**
     * A persistent SOCKS5 connection to a DNS server through the dnstt tunnel.
     * Reused across multiple DNS queries to avoid per-query handshake overhead.
     */
    private inner class DnsTunnelConnection(val targetServer: String) {
        var socket: Socket? = null
        var input: InputStream? = null
        var output: OutputStream? = null
        var createdAt: Long = System.currentTimeMillis()
        var lastUsed: Long = System.currentTimeMillis()

        fun isValid(): Boolean {
            val s = socket ?: return false
            return !s.isClosed && s.isConnected &&
                    (System.currentTimeMillis() - lastUsed) < DNS_CONN_IDLE_MS
        }

        /** Send a DNS query and read the response over the existing TCP connection. */
        fun query(dnsQuery: ByteArray): ByteArray? {
            val out = output ?: return null
            val inp = input ?: return null

            // Send: 2-byte length prefix + DNS payload (RFC 1035 §4.2.2)
            val req = ByteArray(2 + dnsQuery.size)
            req[0] = ((dnsQuery.size shr 8) and 0xFF).toByte()
            req[1] = (dnsQuery.size and 0xFF).toByte()
            System.arraycopy(dnsQuery, 0, req, 2, dnsQuery.size)
            out.write(req)
            out.flush()

            // Read: 2-byte length prefix + DNS response
            val lenBuf = ByteArray(2)
            readFully(inp, lenBuf)
            val len = ((lenBuf[0].toInt() and 0xFF) shl 8) or (lenBuf[1].toInt() and 0xFF)
            if (len <= 0 || len > 65535) return null

            val resp = ByteArray(len)
            readFully(inp, resp)
            lastUsed = System.currentTimeMillis()
            return resp
        }

        fun close() {
            try { socket?.close() } catch (_: Exception) {}
            socket = null; input = null; output = null
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_CONNECT -> {
                proxyHost = intent.getStringExtra(EXTRA_PROXY_HOST) ?: "127.0.0.1"
                proxyPort = intent.getIntExtra(EXTRA_PROXY_PORT, 7000)
                dnsServer = intent.getStringExtra(EXTRA_DNS_SERVER) ?: "8.8.8.8"
                tunnelDomain = intent.getStringExtra(EXTRA_TUNNEL_DOMAIN) ?: ""
                publicKey = intent.getStringExtra(EXTRA_PUBLIC_KEY) ?: ""
                isSshMode = intent.getBooleanExtra(EXTRA_SSH_MODE, false)
                socksUsername = intent.getStringExtra(EXTRA_SOCKS_USERNAME)
                socksPassword = intent.getStringExtra(EXTRA_SOCKS_PASSWORD)
                // Run connect on background thread to avoid ANR
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

    private fun startDnsttClient(): Boolean {
        if (tunnelDomain.isEmpty() || publicKey.isEmpty()) {
            Log.e(TAG, "Tunnel domain or public key not provided")
            return false
        }

        try {
            // Clean up any previous client
            stopDnsttClient()

            // Wait for port to be available
            if (isPortInUse(proxyPort)) {
                Log.w(TAG, "Port $proxyPort still in use, waiting...")
                waitForPortRelease(proxyPort)
                if (isPortInUse(proxyPort)) {
                    Log.e(TAG, "Port $proxyPort still in use after waiting")
                    return false
                }
            }

            Log.d(TAG, "Starting Go-based DNSTT client")
            Log.d(TAG, "DNS Server: $dnsServer, Domain: $tunnelDomain")
            Log.d(TAG, "Listen address: $proxyHost:$proxyPort")

            // Create the Go dnstt client
            val listenAddr = "$proxyHost:$proxyPort"
            dnsttClient = Mobile.newClient(dnsServer, tunnelDomain, publicKey, listenAddr)

            // Start the client (this may block while establishing connection)
            dnsttClient?.start()

            Log.d(TAG, "DNSTT client started successfully")

            // Small delay to ensure socket is fully listening
            Thread.sleep(100)

            // Verify it's running
            val running = dnsttClient?.isRunning ?: false
            Log.d(TAG, "DNSTT client running: $running")

            if (running) {
                // Try to verify SOCKS5 proxy is actually listening
                if (verifySocks5Listening()) {
                    Log.d(TAG, "SOCKS5 proxy verified listening on $proxyHost:$proxyPort")
                    return true
                } else {
                    Log.w(TAG, "SOCKS5 proxy not responding, but client reports running")
                    return true // Still return true, let connections try
                }
            }

            return running

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start dnstt client", e)
            return false
        }
    }

    private fun verifySocks5Listening(): Boolean {
        return try {
            val socket = java.net.Socket()
            socket.connect(java.net.InetSocketAddress(proxyHost, proxyPort), 2000)
            socket.close()
            true
        } catch (e: Exception) {
            Log.w(TAG, "SOCKS5 verify failed: ${e.message}")
            false
        }
    }

    private fun stopDnsttClient() {
        dnsttClient?.let { client ->
            try {
                client.stop()
                Log.d(TAG, "DNSTT client stopped")
                // Wait for port to be released
                Thread.sleep(500)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping dnstt client", e)
            }
        }
        dnsttClient = null
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
            Log.d(TAG, "Waiting for port $port to be released...")
            Thread.sleep(200)
        }
    }

    private fun connect() {
        if (isRunning.get()) {
            Log.d(TAG, "VPN already running")
            return
        }

        try {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("connecting")
            }

            createNotificationChannel()
            startForeground(NOTIFICATION_ID, createNotification("connecting"))

            // Acquire wake lock to prevent CPU from sleeping
            acquireWakeLock()

            // TCP: up to 8 concurrent SYN handshakes through the tunnel
            tcpExecutor = Executors.newFixedThreadPool(8)

            // DNS: 2 threads, queue max 4. Excess queries are silently dropped
            // (Android retries DNS automatically). This prevents DNS from starving TCP.
            dnsExecutor = ThreadPoolExecutor(
                2, 2, 0L, TimeUnit.MILLISECONDS,
                LinkedBlockingQueue<Runnable>(4),
                ThreadPoolExecutor.DiscardOldestPolicy()
            )

            // IMPORTANT: Establish VPN interface FIRST with app exclusion
            // This ensures dnstt client's sockets bypass the VPN
            val builder = Builder()
                .setSession("DNSTT Tunnel")
                .addAddress("10.0.0.2", 32)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(dnsServer)
                .setMtu(1500)
                .setBlocking(true)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                builder.addDisallowedApplication(packageName)
            }

            vpnInterface = builder.establish()

            if (vpnInterface == null) {
                Log.e(TAG, "Failed to establish VPN interface")
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    stateCallback?.invoke("error")
                }
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            Log.d(TAG, "VPN interface established, app is excluded from routing")

            // Wait for VPN routing to be fully active
            Thread.sleep(500)
            Log.d(TAG, "VPN routing settled")

            // In SSH mode, the SOCKS5 proxy is already running (started by MainActivity)
            // In normal mode, start dnstt-client
            if (!isSshMode) {
                Log.d(TAG, "Starting dnstt client")
                if (!startDnsttClient()) {
                    Log.e(TAG, "Failed to start dnstt-client tunnel")
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        stateCallback?.invoke("error")
                    }
                    vpnInterface?.close()
                    vpnInterface = null
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return
                }
                Log.d(TAG, "dnstt-client tunnel started successfully")
            } else {
                Log.d(TAG, "SSH mode - using existing SOCKS5 proxy on port $proxyPort")
            }

            isRunning.set(true)
            shouldRun.set(true)

            // Update notification to connected state
            updateNotification("connected")

            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("connected")
            }

            runningThread = Thread {
                runVpnLoop()
            }
            runningThread?.start()

            Log.d(TAG, "VPN connected successfully with dnstt tunnel")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to connect VPN", e)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("error")
            }
            disconnect()
        }
    }

    private fun runVpnLoop() {
        val vpnFd = vpnInterface?.fileDescriptor ?: return
        val inputStream = FileInputStream(vpnFd)
        val outputStream = FileOutputStream(vpnFd)
        val packet = ByteBuffer.allocate(32767)

        try {
            while (shouldRun.get()) {
                val length = inputStream.channel.read(packet)
                if (length > 0) {
                    packet.flip()
                    val packetBytes = ByteArray(length)
                    packet.get(packetBytes)
                    
                    val ipHeader = IPv4Header.parse(packetBytes)
                    if (ipHeader != null) {
                        when (ipHeader.protocol) {
                            6.toByte() -> processTcpPacket(ipHeader, outputStream)
                            17.toByte() -> processUdpPacket(ipHeader, outputStream)
                            1.toByte() -> Log.d(TAG, "ICMP packet discarded")
                        }
                    }

                    packet.clear()
                } else {
                    Thread.sleep(1)
                }
            }
        } catch (e: Exception) {
            if (shouldRun.get()) {
                Log.e(TAG, "VPN loop error", e)
            }
        } finally {
            try {
                inputStream.close()
                outputStream.close()
            } catch (e: Exception) {
                Log.e(TAG, "Error closing streams", e)
            }
        }
    }

    private fun processTcpPacket(ipHeader: IPv4Header, vpnOutput: FileOutputStream) {
        val tcpHeader = TCPHeader.parse(ipHeader.payload) ?: return
        val connectionId = "${ipHeader.sourceIp}:${tcpHeader.sourcePort}-${ipHeader.destinationIp}:${tcpHeader.destinationPort}"

        if (tcpHeader.isSYN && !tcpHeader.isACK) {
            // Handle SYN in a separate thread so the VPN loop isn't blocked
            // while waiting for the SOCKS5 handshake through the slow tunnel
            val destHost = ipHeader.destinationIp.hostAddress ?: return
            val destPort = tcpHeader.destinationPort
            val seqNum = tcpHeader.sequenceNumber
            val srcIp = ipHeader.sourceIp
            val srcPort = tcpHeader.sourcePort
            val destIp = ipHeader.destinationIp

            tcpExecutor?.submit {
                val socks5Client = Socks5Client(
                    proxyHost,
                    proxyPort,
                    destHost,
                    destPort,
                    socksUsername,
                    socksPassword
                )

                val tcpConnection = TcpConnection(
                    sourceIp = srcIp,
                    sourcePort = srcPort,
                    destIp = destIp,
                    destPort = destPort,
                    vpnOutput = vpnOutput,
                    socks5Client = socks5Client
                )

                if (tcpConnection.handleSyn(seqNum)) {
                    tcpConnections[connectionId] = tcpConnection
                    Log.d(TAG, "New TCP connection: $connectionId")
                } else {
                    Log.e(TAG, "Failed to establish connection: $connectionId")
                }
            }
        } else if (tcpHeader.isFIN) {
            tcpConnections[connectionId]?.handleFin(tcpHeader.sequenceNumber)
            tcpConnections.remove(connectionId)
        } else if (tcpHeader.isRST) {
            tcpConnections[connectionId]?.close()
            tcpConnections.remove(connectionId)
        } else if (tcpHeader.isACK) {
            // ACK packet (possibly with data)
            tcpConnections[connectionId]?.handleAck(
                tcpHeader.sequenceNumber,
                tcpHeader.acknowledgmentNumber,
                tcpHeader.payload
            )
        }
    }


    private fun processUdpPacket(ipHeader: IPv4Header, vpnOutput: FileOutputStream) {
        val udpHeader = UDPHeader.parse(ipHeader.payload) ?: return

        // Only handle DNS queries (port 53)
        if (udpHeader.destinationPort != 53) {
            Log.d(TAG, "Non-DNS UDP packet discarded (port ${udpHeader.destinationPort})")
            return
        }

        Log.d(TAG, "DNS query from ${ipHeader.sourceIp}:${udpHeader.sourcePort} to ${ipHeader.destinationIp}:53")

        // Forward DNS query through the SOCKS5 tunnel using DNS-over-TCP
        // This prevents DNS leakage by routing queries through the dnstt tunnel
        dnsExecutor?.submit {
            try {
                // Always resolve through the configured DNS server, not the packet's
                // destination IP — the destination may be a local/private DNS (e.g.
                // emulator's 10.0.2.3) that isn't reachable through the tunnel.
                val dnsResponse = resolveDnsThroughTunnel(udpHeader.payload, dnsServer)
                if (dnsResponse == null) {
                    Log.e(TAG, "DNS resolution through tunnel failed")
                    return@submit
                }

                Log.d(TAG, "DNS response received via tunnel: ${dnsResponse.size} bytes")

                // Build UDP response packet to inject back into TUN
                val responseUdp = UDPHeader(
                    sourcePort = 53,
                    destinationPort = udpHeader.sourcePort,
                    length = 8 + dnsResponse.size,
                    checksum = 0,
                    payload = dnsResponse
                )

                val responseIp = IPv4Header(
                    version = 4,
                    ihl = 5,
                    totalLength = 20 + 8 + dnsResponse.size,
                    identification = ipHeader.identification + 1,
                    flags = 0,
                    fragmentOffset = 0,
                    ttl = 64,
                    protocol = 17, // UDP
                    headerChecksum = 0,
                    sourceIp = ipHeader.destinationIp,
                    destinationIp = ipHeader.sourceIp,
                    payload = responseUdp.toByteArray(ipHeader.destinationIp, ipHeader.sourceIp)
                )

                val fullPacket = responseIp.toByteArrayForUdp()
                synchronized(vpnOutput) {
                    vpnOutput.write(fullPacket)
                    vpnOutput.flush()
                }
                Log.d(TAG, "DNS response sent back to client via tunnel")

            } catch (e: Exception) {
                Log.e(TAG, "DNS forwarding through tunnel failed", e)
            }
        }
    }

    /**
     * Resolves a DNS query using a pooled SOCKS5 connection through the dnstt tunnel.
     * Reuses persistent connections to avoid per-query SOCKS5 handshake overhead.
     * If a pooled connection fails, retries once with a fresh connection.
     */
    private fun resolveDnsThroughTunnel(dnsQuery: ByteArray, targetDnsServer: String): ByteArray? {
        // First attempt: try a pooled connection
        val pooled = acquireDnsConnection(targetDnsServer)
        if (pooled != null) {
            try {
                val result = pooled.query(dnsQuery)
                if (result != null) {
                    releaseDnsConnection(pooled)
                    return result
                }
            } catch (e: Exception) {
                Log.d(TAG, "Pooled DNS connection stale, retrying with fresh connection")
            }
            pooled.close()
        }

        // Second attempt: fresh connection
        val fresh = createDnsConnection(targetDnsServer) ?: return null
        try {
            val result = fresh.query(dnsQuery)
            if (result != null) {
                releaseDnsConnection(fresh)
            } else {
                fresh.close()
            }
            return result
        } catch (e: Exception) {
            Log.e(TAG, "DNS query failed on fresh connection", e)
            fresh.close()
            return null
        }
    }

    /** Get a connection from the pool or create a new one. */
    private fun acquireDnsConnection(targetDnsServer: String): DnsTunnelConnection? {
        // Try to reuse an existing valid connection to the same server
        while (true) {
            val conn = dnsConnPool.pollFirst() ?: break
            if (conn.isValid() && conn.targetServer == targetDnsServer) {
                return conn
            }
            conn.close()
        }
        // Create a new connection
        return createDnsConnection(targetDnsServer)
    }

    /** Return a connection to the pool for reuse. */
    private fun releaseDnsConnection(conn: DnsTunnelConnection) {
        if (!shouldRun.get() || dnsConnPool.size >= DNS_POOL_MAX || !conn.isValid()) {
            conn.close()
            return
        }
        dnsConnPool.offerFirst(conn)
    }

    /** Close all pooled DNS connections. */
    private fun drainDnsPool() {
        while (true) {
            val conn = dnsConnPool.pollFirst() ?: break
            conn.close()
        }
    }

    /**
     * Create a new SOCKS5 connection through the dnstt tunnel to a DNS server.
     * Performs the full SOCKS5 handshake + CONNECT once; the returned connection
     * can then be used for multiple DNS-over-TCP queries.
     */
    private fun createDnsConnection(targetDnsServer: String): DnsTunnelConnection? {
        try {
            val socket = Socket()
            socket.connect(InetSocketAddress(proxyHost, proxyPort), 10000)
            socket.soTimeout = 10000
            socket.tcpNoDelay = true

            val input = socket.getInputStream()
            val output = socket.getOutputStream()

            // --- SOCKS5 handshake ---
            val requiresAuth = !socksUsername.isNullOrEmpty() && !socksPassword.isNullOrEmpty()
            val greeting = if (requiresAuth) {
                byteArrayOf(0x05, 2, 0x00, 0x02)
            } else {
                byteArrayOf(0x05, 1, 0x00)
            }
            output.write(greeting)
            output.flush()

            val greetingResponse = ByteArray(2)
            readFully(input, greetingResponse)
            if (greetingResponse[0] != 0x05.toByte()) {
                Log.e(TAG, "Invalid SOCKS5 greeting for DNS pool connection")
                socket.close()
                return null
            }

            when (greetingResponse[1].toInt() and 0xFF) {
                0x00 -> { /* No auth needed */ }
                0x02 -> {
                    if (!requiresAuth) {
                        Log.e(TAG, "SOCKS5 requires auth but no credentials for DNS pool")
                        socket.close()
                        return null
                    }
                    val usernameBytes = socksUsername!!.toByteArray()
                    val passwordBytes = socksPassword!!.toByteArray()
                    val authReq = ByteArray(3 + usernameBytes.size + passwordBytes.size)
                    authReq[0] = 0x01
                    authReq[1] = usernameBytes.size.toByte()
                    System.arraycopy(usernameBytes, 0, authReq, 2, usernameBytes.size)
                    authReq[2 + usernameBytes.size] = passwordBytes.size.toByte()
                    System.arraycopy(passwordBytes, 0, authReq, 3 + usernameBytes.size, passwordBytes.size)
                    output.write(authReq)
                    output.flush()

                    val authResp = ByteArray(2)
                    readFully(input, authResp)
                    if (authResp[1] != 0x00.toByte()) {
                        Log.e(TAG, "SOCKS5 auth failed for DNS pool connection")
                        socket.close()
                        return null
                    }
                }
                else -> {
                    Log.e(TAG, "Unsupported SOCKS5 auth method for DNS pool")
                    socket.close()
                    return null
                }
            }

            // --- SOCKS5 CONNECT to target DNS server on port 53 ---
            val dnsServerAddr = InetAddress.getByName(targetDnsServer)
            val ipBytes = dnsServerAddr.address
            val connectReq = byteArrayOf(
                0x05, 0x01, 0x00,   // VER, CMD=CONNECT, RSV
                0x01,               // ATYP=IPv4
                ipBytes[0], ipBytes[1], ipBytes[2], ipBytes[3],
                0x00, 0x35          // Port 53
            )
            output.write(connectReq)
            output.flush()

            val connectResp = ByteArray(10)
            readFully(input, connectResp)
            if (connectResp[0] != 0x05.toByte() || connectResp[1] != 0x00.toByte()) {
                Log.e(TAG, "SOCKS5 CONNECT to DNS server failed: status=${connectResp[1]}")
                socket.close()
                return null
            }

            Log.d(TAG, "DNS pool: new connection to $targetDnsServer established")
            val conn = DnsTunnelConnection(targetDnsServer)
            conn.socket = socket
            conn.input = input
            conn.output = output
            return conn

        } catch (e: Exception) {
            Log.e(TAG, "Failed to create DNS pool connection", e)
            return null
        }
    }

    /** Reads exactly buffer.size bytes from the stream, or throws IOException. */
    private fun readFully(input: InputStream, buffer: ByteArray) {
        var offset = 0
        while (offset < buffer.size) {
            val bytesRead = input.read(buffer, offset, buffer.size - offset)
            if (bytesRead == -1) throw IOException("Unexpected end of stream reading DNS response")
            offset += bytesRead
        }
    }

    private fun disconnect() {
        Log.d(TAG, "Disconnecting VPN")

        shouldRun.set(false)

        stateCallback?.invoke("disconnecting")

        runningThread?.interrupt()
        runningThread = null

        tcpExecutor?.shutdownNow()
        tcpExecutor = null
        dnsExecutor?.shutdownNow()
        dnsExecutor = null

        tcpConnections.values.forEach { it.close() }
        tcpConnections.clear()

        drainDnsPool()

        try {
            vpnInterface?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing VPN interface", e)
        }
        vpnInterface = null

        // Stop dnstt-client process (only if not in SSH mode, since SSH mode manages its own)
        if (!isSshMode) {
            stopDnsttClient()
        }

        // Release wake lock
        releaseWakeLock()

        isRunning.set(false)
        isSshMode = false
        stateCallback?.invoke("disconnected")

        // Remove notification and stop service
        stopForeground(STOP_FOREGROUND_REMOVE)

        // Also explicitly cancel the notification
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager?.cancel(NOTIFICATION_ID)

        stopSelf()
        Log.d(TAG, "VPN disconnected and service stopped")
    }

    override fun onDestroy() {
        disconnect()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "DNSTT VPN Connection",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows when VPN is connected"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(false)
                setSound(null, null)
            }

            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(state: String = "connecting"): Notification {
        // Intent to open the app when notification is clicked
        val openAppIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Intent to disconnect VPN
        val disconnectIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, DnsttVpnService::class.java).apply {
                action = ACTION_DISCONNECT
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val (title, text, icon) = when (state) {
            "connecting" -> Triple(
                "DNSTT VPN Connecting...",
                "Establishing tunnel via $dnsServer",
                android.R.drawable.ic_popup_sync
            )
            "connected" -> Triple(
                "DNSTT VPN Connected",
                "Tunneling via $dnsServer",
                android.R.drawable.ic_lock_lock
            )
            "disconnecting" -> Triple(
                "DNSTT VPN Disconnecting...",
                "Closing tunnel",
                android.R.drawable.ic_popup_sync
            )
            else -> Triple(
                "DNSTT VPN",
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

        // Add disconnect action only when connected
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
                "DnsttVpnService::WakeLock"
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

    override fun onRevoke() {
        disconnect()
        super.onRevoke()
    }
}

data class IPv4Header(
    val version: Int,
    val ihl: Int,
    val totalLength: Int,
    val identification: Int,
    val flags: Int,
    val fragmentOffset: Int,
    val ttl: Int,
    val protocol: Byte,
    var headerChecksum: Int,
    val sourceIp: InetAddress,
    val destinationIp: InetAddress,
    val payload: ByteArray
) {
    companion object {
        fun parse(data: ByteArray): IPv4Header? {
            if (data.size < 20) return null
            val buffer = ByteBuffer.wrap(data)
            
            val versionAndIhl = buffer.get().toInt()
            val version = versionAndIhl shr 4
            val ihl = versionAndIhl and 0x0F
            if (ihl < 5) return null

            buffer.get() // DSCP & ECN
            val totalLength = buffer.short.toInt() and 0xFFFF
            val identification = buffer.short.toInt() and 0xFFFF
            val flagsAndFragment = buffer.short.toInt() and 0xFFFF
            val flags = flagsAndFragment shr 13
            val fragmentOffset = flagsAndFragment and 0x1FFF
            val ttl = buffer.get().toInt() and 0xFF
            val protocol = buffer.get()
            val headerChecksum = buffer.short.toInt() and 0xFFFF

            val sourceIpBytes = ByteArray(4)
            buffer.get(sourceIpBytes)
            val sourceIp = InetAddress.getByAddress(sourceIpBytes)

            val destIpBytes = ByteArray(4)
            buffer.get(destIpBytes)
            val destinationIp = InetAddress.getByAddress(destIpBytes)
            
            val payload = data.copyOfRange(ihl * 4, totalLength)

            return IPv4Header(
                version, ihl, totalLength, identification, flags,
                fragmentOffset, ttl, protocol, headerChecksum, sourceIp, destinationIp, payload
            )
        }
    }
    
    fun buildPacket(tcpHeader: TCPHeader): ByteArray {
         val ipHeaderBytes = toByteArray()
         val tcpHeaderBytes = tcpHeader.toByteArray(sourceIp, destinationIp)
         return ipHeaderBytes + tcpHeaderBytes
    }

    fun toByteArrayForUdp(): ByteArray {
        val ipHeaderSize = ihl * 4
        val buffer = ByteBuffer.allocate(ipHeaderSize)
        buffer.put(((version shl 4) or ihl).toByte())
        buffer.put(0) // DSCP & ECN
        buffer.putShort(totalLength.toShort())
        buffer.putShort(identification.toShort())
        buffer.putShort(((flags shl 13) or fragmentOffset).toShort())
        buffer.put(ttl.toByte())
        buffer.put(protocol)
        buffer.putShort(0) // Checksum placeholder
        buffer.put(sourceIp.address)
        buffer.put(destinationIp.address)

        // Calculate IP header checksum
        val array = buffer.array()
        val checksum = calculateChecksum(array, 0, ipHeaderSize)
        buffer.putShort(10, checksum.toShort())

        return array + payload
    }

    private fun toByteArray(): ByteArray {
        val buffer = ByteBuffer.allocate(ihl * 4)
        buffer.put(((version shl 4) or ihl).toByte())
        buffer.put(0) // DSCP & ECN
        buffer.putShort(totalLength.toShort())
        buffer.putShort(identification.toShort())
        buffer.putShort(((flags shl 13) or fragmentOffset).toShort())
        buffer.put(ttl.toByte())
        buffer.put(protocol)
        buffer.putShort(0) // Checksum placeholder

        buffer.put(sourceIp.address)
        buffer.put(destinationIp.address)

        // Calculate checksum
        val array = buffer.array()
        val checksum = calculateChecksum(array, 0, buffer.position())
        buffer.putShort(10, checksum.toShort())

        return array
    }
}

data class TCPHeader(
    val sourcePort: Int,
    val destinationPort: Int,
    val sequenceNumber: Long,
    val acknowledgmentNumber: Long,
    val dataOffset: Int,
    val flags: Int,
    val windowSize: Int,
    var checksum: Int,
    val urgentPointer: Int,
    val payload: ByteArray
) {
    companion object {
        const val FLAG_FIN = 1
        const val FLAG_SYN = 2
        const val FLAG_RST = 4
        const val FLAG_PSH = 8
        const val FLAG_ACK = 16
        const val FLAG_URG = 32

        fun parse(data: ByteArray): TCPHeader? {
            if (data.size < 20) return null
            val buffer = ByteBuffer.wrap(data)

            val sourcePort = buffer.short.toInt() and 0xFFFF
            val destinationPort = buffer.short.toInt() and 0xFFFF
            val sequenceNumber = buffer.int.toLong() and 0xFFFFFFFF
            val acknowledgmentNumber = buffer.int.toLong() and 0xFFFFFFFF
            val dataOffsetAndFlags = buffer.short.toInt() and 0xFFFF
            val dataOffset = (dataOffsetAndFlags shr 12) and 0xF
            val flags = dataOffsetAndFlags and 0x1FF
            val windowSize = buffer.short.toInt() and 0xFFFF
            val checksum = buffer.short.toInt() and 0xFFFF
            val urgentPointer = buffer.short.toInt() and 0xFFFF

            val payload = data.copyOfRange(dataOffset * 4, data.size)

            return TCPHeader(
                sourcePort, destinationPort, sequenceNumber, acknowledgmentNumber,
                dataOffset, flags, windowSize, checksum, urgentPointer, payload
            )
        }
    }
    
    val isFIN: Boolean get() = (flags and FLAG_FIN) != 0
    val isSYN: Boolean get() = (flags and FLAG_SYN) != 0
    val isRST: Boolean get() = (flags and FLAG_RST) != 0
    val isACK: Boolean get() = (flags and FLAG_ACK) != 0

    fun toByteArray(sourceIp: InetAddress, destIp: InetAddress): ByteArray {
        val tcpLength = (dataOffset * 4) + payload.size
        val buffer = ByteBuffer.allocate(tcpLength)

        buffer.putShort(sourcePort.toShort())
        buffer.putShort(destinationPort.toShort())
        buffer.putInt(sequenceNumber.toInt())
        buffer.putInt(acknowledgmentNumber.toInt())
        buffer.putShort(((dataOffset shl 12) or flags).toShort())
        buffer.putShort(windowSize.toShort())
        buffer.putShort(0) // Checksum placeholder
        buffer.putShort(urgentPointer.toShort())
        buffer.put(payload)

        // Calculate checksum
        val array = buffer.array()
        val pseudoHeader = createPseudoHeader(sourceIp, destIp, tcpLength)
        val checksum = calculateChecksum(pseudoHeader + array, 0, pseudoHeader.size + array.size)
        buffer.putShort(16, checksum.toShort())

        return array
    }
    
     private fun createPseudoHeader(sourceIp: InetAddress, destIp: InetAddress, tcpLength: Int): ByteArray {
        val buffer = ByteBuffer.allocate(12)
        buffer.put(sourceIp.address)
        buffer.put(destIp.address)
        buffer.put(0.toByte())
        buffer.put(6.toByte()) // Protocol TCP
        buffer.putShort(tcpLength.toShort())
        return buffer.array()
    }
}

fun calculateChecksum(data: ByteArray, offset: Int, length: Int): Int {
    var sum = 0
    var i = offset
    while (i < length - 1) {
        val word = ((data[i].toInt() and 0xFF) shl 8) or (data[i + 1].toInt() and 0xFF)
        sum += word
        i += 2
    }
    if (length % 2 != 0) {
        sum += (data[length - 1].toInt() and 0xFF) shl 8
    }
    while (sum shr 16 > 0) {
        sum = (sum and 0xFFFF) + (sum shr 16)
    }
    return sum.inv() and 0xFFFF
}

data class UDPHeader(
    val sourcePort: Int,
    val destinationPort: Int,
    val length: Int,
    var checksum: Int,
    val payload: ByteArray
) {
    companion object {
        fun parse(data: ByteArray): UDPHeader? {
            if (data.size < 8) return null
            val buffer = ByteBuffer.wrap(data)

            val sourcePort = buffer.short.toInt() and 0xFFFF
            val destinationPort = buffer.short.toInt() and 0xFFFF
            val length = buffer.short.toInt() and 0xFFFF
            val checksum = buffer.short.toInt() and 0xFFFF

            val payload = if (data.size > 8) data.copyOfRange(8, minOf(length, data.size)) else ByteArray(0)

            return UDPHeader(sourcePort, destinationPort, length, checksum, payload)
        }
    }

    fun toByteArray(sourceIp: InetAddress, destIp: InetAddress): ByteArray {
        val buffer = ByteBuffer.allocate(8 + payload.size)
        buffer.putShort(sourcePort.toShort())
        buffer.putShort(destinationPort.toShort())
        buffer.putShort((8 + payload.size).toShort())
        buffer.putShort(0) // Checksum placeholder
        buffer.put(payload)

        // Calculate UDP checksum with pseudo-header
        val array = buffer.array()
        val pseudoHeader = createUdpPseudoHeader(sourceIp, destIp, 8 + payload.size)
        val checksum = calculateChecksum(pseudoHeader + array, 0, pseudoHeader.size + array.size)
        buffer.putShort(6, checksum.toShort())

        return array
    }

    private fun createUdpPseudoHeader(sourceIp: InetAddress, destIp: InetAddress, udpLength: Int): ByteArray {
        val buffer = ByteBuffer.allocate(12)
        buffer.put(sourceIp.address)
        buffer.put(destIp.address)
        buffer.put(0.toByte())
        buffer.put(17.toByte()) // Protocol UDP
        buffer.putShort(udpLength.toShort())
        return buffer.array()
    }
}