package xyz.dnstt.app

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import mobile.Mobile
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import android.net.ConnectivityManager
import android.util.Log
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

    companion object {
        const val VPN_CHANNEL = "xyz.dnstt.app/vpn"
        const val VPN_STATE_CHANNEL = "xyz.dnstt.app/vpn_state"
        const val VPN_REQUEST_CODE = 1001
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1002
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private var pendingResult: MethodChannel.Result? = null
    private var pendingProxyHost: String? = null
    private var pendingProxyPort: Int? = null
    private var pendingDnsServer: String? = null
    private var pendingTunnelDomain: String? = null
    private var pendingPublicKey: String? = null

    // Track running tests for cancellation
    private val runningTests = ConcurrentHashMap<Int, TestContext>()
    private val testsCancelled = AtomicBoolean(false)

    // Proxy-only mode (no VPN) - now uses DnsttProxyService
    private val proxyScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // SSH tunnel mode (DNSTT + SSH dynamic port forwarding)
    // sshDnsttClient is the internal DNSTT client used by SSH tunnel (runs on port 7001)
    private var sshDnsttClient: mobile.DnsttClient? = null
    private var sshTunnelClient: SshTunnelClient? = null
    private val isSshTunnelRunning = AtomicBoolean(false)

    // Proxy sharing mode
    private val isProxySharingEnabled = AtomicBoolean(false)

    private data class TestContext(
        val job: Job,
        val client: mobile.DnsttClient?,
        val httpCall: Call?
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize SlipstreamBridge to detect binary availability
        SlipstreamBridge.init(this)

        // Request notification permission for Android 13+
        requestNotificationPermission()

        // Setup method channel for VPN control
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> requestVpnPermission(result)
                "connect" -> {
                    val proxyHost = call.argument<String>("proxyHost") ?: "127.0.0.1"
                    val proxyPort = call.argument<Int>("proxyPort") ?: 7000
                    val dnsServer = call.argument<String>("dnsServer") ?: "8.8.8.8"
                    val tunnelDomain = call.argument<String>("tunnelDomain") ?: ""
                    val publicKey = call.argument<String>("publicKey") ?: ""
                    connectVpn(proxyHost, proxyPort, dnsServer, tunnelDomain, publicKey, result)
                }
                "disconnect" -> disconnectVpn(result)
                "isConnected" -> result.success(DnsttVpnService.isRunning.get())
                "testDnsServer" -> {
                    val dnsServer = call.argument<String>("dnsServer") ?: ""
                    val tunnelDomain = call.argument<String>("tunnelDomain") ?: ""
                    val publicKey = call.argument<String>("publicKey") ?: ""
                    val testUrl = call.argument<String>("testUrl") ?: "https://api.ipify.org?format=json"
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 15000
                    testDnsServer(dnsServer, tunnelDomain, publicKey, testUrl, timeoutMs, result)
                }
                "cancelAllTests" -> {
                    cancelAllTests()
                    result.success(true)
                }
                "resetTestCancellation" -> {
                    testsCancelled.set(false)
                    result.success(true)
                }
                "connectProxy" -> {
                    val dnsServer = call.argument<String>("dnsServer") ?: "8.8.8.8"
                    val tunnelDomain = call.argument<String>("tunnelDomain") ?: ""
                    val publicKey = call.argument<String>("publicKey") ?: ""
                    val proxyPort = call.argument<Int>("proxyPort") ?: 7000
                    connectProxyOnly(dnsServer, tunnelDomain, publicKey, proxyPort, result)
                }
                "disconnectProxy" -> {
                    disconnectProxyOnly(result)
                }
                "isProxyConnected" -> {
                    result.success(DnsttProxyService.isRunning.get())
                }
                "connectSshTunnel" -> {
                    val dnsServer = call.argument<String>("dnsServer") ?: "8.8.8.8"
                    val tunnelDomain = call.argument<String>("tunnelDomain") ?: ""
                    val publicKey = call.argument<String>("publicKey") ?: ""
                    val sshUsername = call.argument<String>("sshUsername") ?: ""
                    val sshPassword = call.argument<String>("sshPassword")
                    val sshPrivateKey = call.argument<String>("sshPrivateKey")
                    val shareProxy = call.argument<Boolean>("shareProxy") ?: false
                    connectSshTunnel(
                        dnsServer, tunnelDomain, publicKey,
                        sshUsername, sshPassword, sshPrivateKey, shareProxy, result
                    )
                }
                "connectSshTunnelVpn" -> {
                    val dnsServer = call.argument<String>("dnsServer") ?: "8.8.8.8"
                    val tunnelDomain = call.argument<String>("tunnelDomain") ?: ""
                    val publicKey = call.argument<String>("publicKey") ?: ""
                    val sshUsername = call.argument<String>("sshUsername") ?: ""
                    val sshPassword = call.argument<String>("sshPassword")
                    val sshPrivateKey = call.argument<String>("sshPrivateKey")
                    connectSshTunnelWithVpn(
                        dnsServer, tunnelDomain, publicKey,
                        sshUsername, sshPassword, sshPrivateKey, result
                    )
                }
                "disconnectSshTunnel" -> {
                    disconnectSshTunnel(result)
                }
                "isSshTunnelConnected" -> {
                    result.success(isSshTunnelRunning.get() && sshTunnelClient?.isConnected() == true)
                }
                "getLocalIpAddresses" -> {
                    result.success(getLocalIpAddresses())
                }
                "setProxySharing" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    isProxySharingEnabled.set(enabled)
                    // Note: If proxy is already running via service, it would need to be restarted
                    // to change sharing mode. For simplicity, just store the preference.
                    Log.d("DnsttProxy", "Proxy sharing preference set to: $enabled")
                    result.success(true)
                }
                "isProxySharingEnabled" -> {
                    result.success(isProxySharingEnabled.get())
                }
                "connectProxyShared" -> {
                    val dnsServer = call.argument<String>("dnsServer") ?: "8.8.8.8"
                    val tunnelDomain = call.argument<String>("tunnelDomain") ?: ""
                    val publicKey = call.argument<String>("publicKey") ?: ""
                    val proxyPort = call.argument<Int>("proxyPort") ?: 7000
                    connectProxyShared(dnsServer, tunnelDomain, publicKey, proxyPort, result)
                }
                // Slipstream methods
                "connectSlipstream" -> {
                    val dnsServer = call.argument<String>("dnsServer") ?: "8.8.8.8"
                    val tunnelDomain = call.argument<String>("tunnelDomain") ?: ""
                    val congestionControl = call.argument<String>("congestionControl") ?: "dcubic"
                    val keepAliveInterval = call.argument<Int>("keepAliveInterval") ?: 400
                    val gso = call.argument<Boolean>("gso") ?: false
                    connectSlipstreamVpn(dnsServer, tunnelDomain, congestionControl, keepAliveInterval, gso, result)
                }
                "connectSlipstreamProxy" -> {
                    val dnsServer = call.argument<String>("dnsServer") ?: "8.8.8.8"
                    val tunnelDomain = call.argument<String>("tunnelDomain") ?: ""
                    val proxyPort = call.argument<Int>("proxyPort") ?: 7000
                    val congestionControl = call.argument<String>("congestionControl") ?: "dcubic"
                    val keepAliveInterval = call.argument<Int>("keepAliveInterval") ?: 400
                    val gso = call.argument<Boolean>("gso") ?: false
                    connectSlipstreamProxyOnly(dnsServer, tunnelDomain, proxyPort, congestionControl, keepAliveInterval, gso, result)
                }
                "disconnectSlipstreamProxy" -> {
                    disconnectSlipstreamProxyOnly(result)
                }
                "isSlipstreamProxyConnected" -> {
                    result.success(SlipstreamProxyService.isRunning.get())
                }
                "getSystemDns" -> {
                    try {
                        val cm = getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val lp = cm.getLinkProperties(cm.activeNetwork)
                        val dns = lp?.dnsServers?.firstOrNull { !it.hostAddress!!.contains(':') }?.hostAddress
                        result.success(dns)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "testSlipstreamDnsServer" -> {
                    val dnsServer = call.argument<String>("dnsServer") ?: ""
                    val tunnelDomain = call.argument<String>("tunnelDomain") ?: ""
                    val testUrl = call.argument<String>("testUrl") ?: "https://api.ipify.org?format=json"
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 15000
                    val congestionControl = call.argument<String>("congestionControl") ?: "dcubic"
                    val keepAliveInterval = call.argument<Int>("keepAliveInterval") ?: 400
                    val gso = call.argument<Boolean>("gso") ?: false
                    testSlipstreamDnsServer(dnsServer, tunnelDomain, testUrl, timeoutMs, congestionControl, keepAliveInterval, gso, result)
                }
                else -> result.notImplemented()
            }
        }

        // Setup event channel for VPN state updates
        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_STATE_CHANNEL)
        eventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                DnsttVpnService.stateCallback = { state ->
                    runOnUiThread {
                        eventSink?.success(state)
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                DnsttVpnService.stateCallback = null
            }
        })
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(
                    this,
                    android.Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST_CODE
                )
            }
        }
    }

    private fun requestVpnPermission(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            pendingResult = result
            startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            // Permission already granted
            result.success(true)
        }
    }

    private fun connectVpn(
        proxyHost: String,
        proxyPort: Int,
        dnsServer: String,
        tunnelDomain: String,
        publicKey: String,
        result: MethodChannel.Result
    ) {
        pendingTunnelDomain = tunnelDomain
        pendingPublicKey = publicKey
        // Check if VPN permission is granted
        val intent = VpnService.prepare(this)
        if (intent != null) {
            // Need to request permission first
            pendingResult = result
            pendingProxyHost = proxyHost
            pendingProxyPort = proxyPort
            pendingDnsServer = dnsServer
            startActivityForResult(intent, VPN_REQUEST_CODE)
            return
        }

        // Start VPN service
        startVpnService(proxyHost, proxyPort, dnsServer, tunnelDomain, publicKey)
        result.success(true)
    }

    /**
     * Stop any running proxy services before starting a new connection.
     * This prevents duplicate notifications and service conflicts.
     */
    private fun stopAllProxyServices() {
        if (DnsttProxyService.isRunning.get()) {
            Log.d("MainActivity", "Stopping running DNSTT proxy service")
            val intent = Intent(this, DnsttProxyService::class.java).apply {
                action = DnsttProxyService.ACTION_DISCONNECT
            }
            startService(intent)
        }
        if (SlipstreamProxyService.isRunning.get()) {
            Log.d("MainActivity", "Stopping running Slipstream proxy service")
            val intent = Intent(this, SlipstreamProxyService::class.java).apply {
                action = SlipstreamProxyService.ACTION_DISCONNECT
            }
            startService(intent)
        }
    }

    private fun startVpnService(proxyHost: String, proxyPort: Int, dnsServer: String, tunnelDomain: String, publicKey: String) {
        // Stop any proxy services first
        stopAllProxyServices()

        val serviceIntent = Intent(this, DnsttVpnService::class.java).apply {
            action = DnsttVpnService.ACTION_CONNECT
            putExtra(DnsttVpnService.EXTRA_PROXY_HOST, proxyHost)
            putExtra(DnsttVpnService.EXTRA_PROXY_PORT, proxyPort)
            putExtra(DnsttVpnService.EXTRA_DNS_SERVER, dnsServer)
            putExtra(DnsttVpnService.EXTRA_TUNNEL_DOMAIN, tunnelDomain)
            putExtra(DnsttVpnService.EXTRA_PUBLIC_KEY, publicKey)
        }
        startForegroundService(serviceIntent)
    }

    private fun disconnectVpn(result: MethodChannel.Result) {
        val serviceIntent = Intent(this, DnsttVpnService::class.java).apply {
            action = DnsttVpnService.ACTION_DISCONNECT
        }
        startService(serviceIntent)
        result.success(true)
    }

    // Proxy-only mode methods (no VPN, just TCP forwarding through DNSTT)
    // Now uses DnsttProxyService to run in background
    private fun connectProxyOnly(
        dnsServer: String,
        tunnelDomain: String,
        publicKey: String,
        proxyPort: Int,
        result: MethodChannel.Result
    ) {
        if (DnsttProxyService.isRunning.get()) {
            result.success(true)
            return
        }

        // Stop VPN and other proxy services
        stopAllProxyServices()
        if (DnsttVpnService.isRunning.get()) {
            val vpnIntent = Intent(this, DnsttVpnService::class.java).apply {
                action = DnsttVpnService.ACTION_DISCONNECT
            }
            startService(vpnIntent)
        }

        Log.d("DnsttProxy", "Starting proxy service on port $proxyPort")

        // Set up state callback to receive events from service
        DnsttProxyService.stateCallback = { state ->
            runOnUiThread {
                eventSink?.success(state)
            }
        }

        // Start the proxy service
        val serviceIntent = Intent(this, DnsttProxyService::class.java).apply {
            action = DnsttProxyService.ACTION_CONNECT
            putExtra(DnsttProxyService.EXTRA_DNS_SERVER, dnsServer)
            putExtra(DnsttProxyService.EXTRA_TUNNEL_DOMAIN, tunnelDomain)
            putExtra(DnsttProxyService.EXTRA_PUBLIC_KEY, publicKey)
            putExtra(DnsttProxyService.EXTRA_PROXY_PORT, proxyPort)
            putExtra(DnsttProxyService.EXTRA_SHARE_PROXY, false)
        }
        startForegroundService(serviceIntent)
        result.success(true)
    }

    private fun disconnectProxyOnly(result: MethodChannel.Result) {
        Log.d("DnsttProxy", "Stopping proxy service")

        val serviceIntent = Intent(this, DnsttProxyService::class.java).apply {
            action = DnsttProxyService.ACTION_DISCONNECT
        }
        startService(serviceIntent)
        isProxySharingEnabled.set(false)
        result.success(true)
    }

    // Get local IP addresses for proxy sharing display
    private fun getLocalIpAddresses(): List<String> {
        val addresses = mutableListOf<String>()
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                // Skip loopback and down interfaces
                if (networkInterface.isLoopback || !networkInterface.isUp) continue

                val addrs = networkInterface.inetAddresses
                while (addrs.hasMoreElements()) {
                    val addr = addrs.nextElement()
                    // Only include IPv4 addresses
                    if (addr is java.net.Inet4Address && !addr.isLoopbackAddress) {
                        val ip = addr.hostAddress
                        // Include local network addresses
                        if (ip != null && (ip.startsWith("192.168.") || ip.startsWith("10.") || ip.startsWith("172."))) {
                            addresses.add(ip)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("DnsttProxy", "Error getting IP addresses: ${e.message}")
        }
        return addresses
    }

    // Connect proxy with sharing enabled (binds to 0.0.0.0)
    private fun connectProxyShared(
        dnsServer: String,
        tunnelDomain: String,
        publicKey: String,
        proxyPort: Int,
        result: MethodChannel.Result
    ) {
        if (DnsttProxyService.isRunning.get()) {
            result.success(true)
            return
        }

        Log.d("DnsttProxy", "Starting shared proxy service on port $proxyPort")
        isProxySharingEnabled.set(true)

        // Set up state callback
        DnsttProxyService.stateCallback = { state ->
            runOnUiThread {
                eventSink?.success(state)
            }
        }

        // Start the proxy service with sharing enabled
        val serviceIntent = Intent(this, DnsttProxyService::class.java).apply {
            action = DnsttProxyService.ACTION_CONNECT
            putExtra(DnsttProxyService.EXTRA_DNS_SERVER, dnsServer)
            putExtra(DnsttProxyService.EXTRA_TUNNEL_DOMAIN, tunnelDomain)
            putExtra(DnsttProxyService.EXTRA_PUBLIC_KEY, publicKey)
            putExtra(DnsttProxyService.EXTRA_PROXY_PORT, proxyPort)
            putExtra(DnsttProxyService.EXTRA_SHARE_PROXY, true)
        }
        startForegroundService(serviceIntent)
        result.success(true)
    }

    // Slipstream VPN mode
    private fun connectSlipstreamVpn(
        dnsServer: String,
        tunnelDomain: String,
        congestionControl: String,
        keepAliveInterval: Int,
        gso: Boolean,
        result: MethodChannel.Result
    ) {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            pendingResult = result
            pendingSlipstreamVpnParams = SlipstreamVpnParams(dnsServer, tunnelDomain, congestionControl, keepAliveInterval, gso)
            startActivityForResult(intent, VPN_REQUEST_CODE)
            return
        }

        startSlipstreamVpnService(dnsServer, tunnelDomain, congestionControl, keepAliveInterval, gso)
        result.success(true)
    }

    private data class SlipstreamVpnParams(
        val dnsServer: String,
        val tunnelDomain: String,
        val congestionControl: String,
        val keepAliveInterval: Int,
        val gso: Boolean
    )

    private var pendingSlipstreamVpnParams: SlipstreamVpnParams? = null

    private fun startSlipstreamVpnService(
        dnsServer: String,
        tunnelDomain: String,
        congestionControl: String,
        keepAliveInterval: Int,
        gso: Boolean
    ) {
        // Stop any proxy services first
        stopAllProxyServices()

        val serviceIntent = Intent(this, DnsttVpnService::class.java).apply {
            action = DnsttVpnService.ACTION_CONNECT
            putExtra(DnsttVpnService.EXTRA_PROXY_HOST, "127.0.0.1")
            putExtra(DnsttVpnService.EXTRA_PROXY_PORT, 7000)
            putExtra(DnsttVpnService.EXTRA_DNS_SERVER, dnsServer)
            putExtra(DnsttVpnService.EXTRA_TUNNEL_DOMAIN, tunnelDomain)
            putExtra(DnsttVpnService.EXTRA_PUBLIC_KEY, "")
            putExtra(DnsttVpnService.EXTRA_TRANSPORT_TYPE, "slipstream")
            putExtra(DnsttVpnService.EXTRA_CONGESTION_CONTROL, congestionControl)
            putExtra(DnsttVpnService.EXTRA_KEEP_ALIVE_INTERVAL, keepAliveInterval)
            putExtra(DnsttVpnService.EXTRA_GSO, gso)
        }
        startForegroundService(serviceIntent)
    }

    // Slipstream proxy-only mode
    private fun connectSlipstreamProxyOnly(
        dnsServer: String,
        tunnelDomain: String,
        proxyPort: Int,
        congestionControl: String,
        keepAliveInterval: Int,
        gso: Boolean,
        result: MethodChannel.Result
    ) {
        if (SlipstreamProxyService.isRunning.get()) {
            result.success(true)
            return
        }

        // Stop VPN and other proxy services
        stopAllProxyServices()
        if (DnsttVpnService.isRunning.get()) {
            val vpnIntent = Intent(this, DnsttVpnService::class.java).apply {
                action = DnsttVpnService.ACTION_DISCONNECT
            }
            startService(vpnIntent)
        }

        Log.d("SlipstreamProxy", "Starting slipstream proxy service on port $proxyPort")

        SlipstreamProxyService.stateCallback = { state ->
            runOnUiThread {
                eventSink?.success(state)
            }
        }

        val serviceIntent = Intent(this, SlipstreamProxyService::class.java).apply {
            action = SlipstreamProxyService.ACTION_CONNECT
            putExtra(SlipstreamProxyService.EXTRA_DNS_SERVER, dnsServer)
            putExtra(SlipstreamProxyService.EXTRA_TUNNEL_DOMAIN, tunnelDomain)
            putExtra(SlipstreamProxyService.EXTRA_PROXY_PORT, proxyPort)
            putExtra(SlipstreamProxyService.EXTRA_CONGESTION_CONTROL, congestionControl)
            putExtra(SlipstreamProxyService.EXTRA_KEEP_ALIVE_INTERVAL, keepAliveInterval)
            putExtra(SlipstreamProxyService.EXTRA_GSO, gso)
            putExtra(SlipstreamProxyService.EXTRA_SHARE_PROXY, false)
        }
        startForegroundService(serviceIntent)
        result.success(true)
    }

    private fun disconnectSlipstreamProxyOnly(result: MethodChannel.Result) {
        Log.d("SlipstreamProxy", "Stopping slipstream proxy service")

        val serviceIntent = Intent(this, SlipstreamProxyService::class.java).apply {
            action = SlipstreamProxyService.ACTION_DISCONNECT
        }
        startService(serviceIntent)
        result.success(true)
    }

    // Slipstream DNS server testing
    private fun testSlipstreamDnsServer(
        dnsServer: String,
        tunnelDomain: String,
        testUrl: String,
        timeoutMs: Int,
        congestionControl: String,
        keepAliveInterval: Int,
        gso: Boolean,
        result: MethodChannel.Result
    ) {
        if (!SlipstreamBridge.isAvailable()) {
            Log.e("SlipstreamTest", "Slipstream library not available")
            result.success(-1)
            return
        }

        if (testsCancelled.get()) {
            result.success(-2)
            return
        }

        val port = getNextTestPort()

        val job = testScope.launch {
            var bridge: SlipstreamBridge? = null
            var resultSent = false

            fun sendResult(value: Int) {
                if (!resultSent) {
                    resultSent = true
                    runBlocking(Dispatchers.Main) { result.success(value) }
                }
            }

            try {
                if (testsCancelled.get()) {
                    sendResult(-2)
                    return@launch
                }

                bridge = SlipstreamBridge()
                val started = bridge.startClient(
                    domain = tunnelDomain,
                    dnsServer = dnsServer,
                    congestionControl = congestionControl,
                    keepAliveInterval = keepAliveInterval,
                    port = port,
                    host = "127.0.0.1",
                    gso = gso
                )

                if (!started) {
                    Log.e("SlipstreamTest", "Failed to start test client: ${bridge.lastError}")
                    sendResult(-1)
                    return@launch
                }

                delay(1000)

                if (testsCancelled.get()) {
                    bridge.stopClient()
                    sendResult(-2)
                    return@launch
                }

                // Make HTTP request through the SOCKS5 proxy
                val startTime = System.currentTimeMillis()
                val proxy = java.net.Proxy(
                    java.net.Proxy.Type.SOCKS,
                    java.net.InetSocketAddress("127.0.0.1", port)
                )

                val httpClient = okhttp3.OkHttpClient.Builder()
                    .proxy(proxy)
                    .connectTimeout(timeoutMs.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
                    .readTimeout(timeoutMs.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
                    .writeTimeout(timeoutMs.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
                    .build()

                val request = okhttp3.Request.Builder().url(testUrl).build()
                val response = httpClient.newCall(request).execute()
                val responseCode = response.code
                val latency = (System.currentTimeMillis() - startTime).toInt()
                response.close()

                bridge.stopClient()

                if (responseCode in 200..399) {
                    sendResult(latency)
                } else {
                    sendResult(-1)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                bridge?.stopClient()
                sendResult(-2)
            } catch (e: Exception) {
                Log.e("SlipstreamTest", "Test failed: ${e.message}", e)
                bridge?.stopClient()
                sendResult(-1)
            }
        }

        runningTests[port] = TestContext(job, null, null)
    }

    // SSH tunnel mode methods
    // Flow: DNSTT tunnel (port 7001 internal) -> SSH client -> SSH dynamic port forwarding -> local SOCKS5 proxy (port 1080)
    private fun connectSshTunnel(
        dnsServer: String,
        tunnelDomain: String,
        publicKey: String,
        sshUsername: String,
        sshPassword: String?,
        sshPrivateKey: String?,
        shareProxy: Boolean,
        result: MethodChannel.Result
    ) {
        if (isSshTunnelRunning.get()) {
            result.success(true)
            return
        }

        Log.d("DnsttSsh", "Starting SSH tunnel mode")

        proxyScope.launch {
            try {
                // Step 1: Start DNSTT proxy on internal port 7001 (creates tunnel to SSH server)
                val listenAddr = "127.0.0.1:7001"
                sshDnsttClient = Mobile.newClient(dnsServer, tunnelDomain, publicKey, listenAddr)
                sshDnsttClient?.start()
                Log.d("DnsttSsh", "DNSTT tunnel started on $listenAddr")

                // Wait for DNSTT to be ready
                delay(500)

                // Step 2: Connect SSH client through DNSTT tunnel, SOCKS5 on port 1080
                sshTunnelClient = SshTunnelClient()
                val sshConnected = sshTunnelClient?.connect(
                    username = sshUsername,
                    password = sshPassword,
                    privateKey = sshPrivateKey,
                    shareProxy = shareProxy
                ) ?: false

                if (sshConnected) {
                    isSshTunnelRunning.set(true)
                    Log.d("DnsttSsh", "SSH tunnel connected, SOCKS5 proxy on port 1080 (sharing: $shareProxy)")

                    runOnUiThread {
                        eventSink?.success("ssh_tunnel_connected")
                        result.success(true)
                    }
                } else {
                    val error = sshTunnelClient?.lastError ?: "SSH connection failed"
                    Log.e("DnsttSsh", "SSH connection failed: $error")

                    // Clean up DNSTT proxy
                    sshDnsttClient?.stop()
                    sshDnsttClient = null
                    sshTunnelClient = null

                    runOnUiThread {
                        eventSink?.success("ssh_tunnel_error")
                        result.success(false)
                    }
                }
            } catch (e: Exception) {
                Log.e("DnsttSsh", "Failed to start SSH tunnel: ${e.message}", e)

                // Clean up
                try {
                    sshDnsttClient?.stop()
                } catch (_: Exception) {}
                sshDnsttClient = null
                sshTunnelClient?.disconnect()
                sshTunnelClient = null
                isSshTunnelRunning.set(false)

                runOnUiThread {
                    eventSink?.success("ssh_tunnel_error")
                    result.success(false)
                }
            }
        }
    }

    private fun disconnectSshTunnel(result: MethodChannel.Result) {
        Log.d("DnsttSsh", "Stopping SSH tunnel mode")

        proxyScope.launch {
            try {
                // Stop VPN service if running (for SSH tunnel VPN mode)
                if (DnsttVpnService.isRunning.get()) {
                    Log.d("DnsttSsh", "Stopping VPN service")
                    runOnUiThread {
                        val serviceIntent = Intent(this@MainActivity, DnsttVpnService::class.java).apply {
                            action = DnsttVpnService.ACTION_DISCONNECT
                        }
                        startService(serviceIntent)
                    }
                }

                // Disconnect SSH
                sshTunnelClient?.disconnect()
                sshTunnelClient = null
                isSshTunnelRunning.set(false)

                // Then stop DNSTT proxy
                sshDnsttClient?.stop()
                sshDnsttClient = null

                Log.d("DnsttSsh", "SSH tunnel stopped")

                runOnUiThread {
                    eventSink?.success("ssh_tunnel_disconnected")
                    result.success(true)
                }
            } catch (e: Exception) {
                Log.e("DnsttSsh", "Error stopping SSH tunnel: ${e.message}", e)
                isSshTunnelRunning.set(false)
                runOnUiThread {
                    eventSink?.success("ssh_tunnel_disconnected")
                    result.success(true)
                }
            }
        }
    }

    // SSH tunnel with VPN mode - routes all device traffic through SSH tunnel
    private fun connectSshTunnelWithVpn(
        dnsServer: String,
        tunnelDomain: String,
        publicKey: String,
        sshUsername: String,
        sshPassword: String?,
        sshPrivateKey: String?,
        result: MethodChannel.Result
    ) {
        // Check VPN permission first
        val intent = VpnService.prepare(this)
        if (intent != null) {
            pendingResult = result
            pendingSshVpnParams = SshVpnParams(dnsServer, tunnelDomain, publicKey, sshUsername, sshPassword, sshPrivateKey)
            startActivityForResult(intent, VPN_REQUEST_CODE)
            return
        }

        // Permission granted, proceed with connection
        startSshTunnelWithVpn(dnsServer, tunnelDomain, publicKey, sshUsername, sshPassword, sshPrivateKey, result)
    }

    private data class SshVpnParams(
        val dnsServer: String,
        val tunnelDomain: String,
        val publicKey: String,
        val sshUsername: String,
        val sshPassword: String?,
        val sshPrivateKey: String?
    )

    private var pendingSshVpnParams: SshVpnParams? = null

    private fun startSshTunnelWithVpn(
        dnsServer: String,
        tunnelDomain: String,
        publicKey: String,
        sshUsername: String,
        sshPassword: String?,
        sshPrivateKey: String?,
        result: MethodChannel.Result
    ) {
        if (isSshTunnelRunning.get()) {
            result.success(true)
            return
        }

        Log.d("DnsttSsh", "Starting SSH tunnel with VPN mode")

        proxyScope.launch {
            try {
                // Step 1: Start DNSTT proxy on internal port 7001
                val listenAddr = "127.0.0.1:7001"
                sshDnsttClient = Mobile.newClient(dnsServer, tunnelDomain, publicKey, listenAddr)
                sshDnsttClient?.start()
                Log.d("DnsttSsh", "DNSTT tunnel started on $listenAddr")

                delay(500)

                // Step 2: Connect SSH client, SOCKS5 on port 7000
                sshTunnelClient = SshTunnelClient()
                val sshConnected = sshTunnelClient?.connect(
                    username = sshUsername,
                    password = sshPassword,
                    privateKey = sshPrivateKey
                ) ?: false

                if (sshConnected) {
                    isSshTunnelRunning.set(true)
                    Log.d("DnsttSsh", "SSH tunnel connected, SOCKS5 proxy on port 7000")

                    // Step 3: Start VPN service to route traffic through SSH SOCKS5 proxy
                    runOnUiThread {
                        startVpnServiceForSsh()
                        result.success(true)
                    }
                } else {
                    val error = sshTunnelClient?.lastError ?: "SSH connection failed"
                    Log.e("DnsttSsh", "SSH connection failed: $error")

                    sshDnsttClient?.stop()
                    sshDnsttClient = null
                    sshTunnelClient = null

                    runOnUiThread {
                        eventSink?.success("ssh_tunnel_error")
                        result.success(false)
                    }
                }
            } catch (e: Exception) {
                Log.e("DnsttSsh", "Failed to start SSH tunnel with VPN: ${e.message}", e)

                try { sshDnsttClient?.stop() } catch (_: Exception) {}
                sshDnsttClient = null
                sshTunnelClient?.disconnect()
                sshTunnelClient = null
                isSshTunnelRunning.set(false)

                runOnUiThread {
                    eventSink?.success("ssh_tunnel_error")
                    result.success(false)
                }
            }
        }
    }

    private fun startVpnServiceForSsh() {
        val serviceIntent = Intent(this, DnsttVpnService::class.java).apply {
            action = DnsttVpnService.ACTION_CONNECT
            putExtra(DnsttVpnService.EXTRA_PROXY_HOST, "127.0.0.1")
            putExtra(DnsttVpnService.EXTRA_PROXY_PORT, 7000)
            putExtra(DnsttVpnService.EXTRA_DNS_SERVER, "8.8.8.8")
            putExtra(DnsttVpnService.EXTRA_TUNNEL_DOMAIN, "")
            putExtra(DnsttVpnService.EXTRA_PUBLIC_KEY, "")
            putExtra(DnsttVpnService.EXTRA_SSH_MODE, true)
        }
        startForegroundService(serviceIntent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                // Permission granted
                if (pendingSlipstreamVpnParams != null) {
                    // Slipstream VPN mode
                    val params = pendingSlipstreamVpnParams!!
                    pendingSlipstreamVpnParams = null
                    startSlipstreamVpnService(
                        params.dnsServer,
                        params.tunnelDomain,
                        params.congestionControl,
                        params.keepAliveInterval,
                        params.gso
                    )
                    pendingResult?.success(true)
                } else if (pendingSshVpnParams != null) {
                    // SSH tunnel with VPN mode
                    val params = pendingSshVpnParams!!
                    pendingSshVpnParams = null
                    startSshTunnelWithVpn(
                        params.dnsServer,
                        params.tunnelDomain,
                        params.publicKey,
                        params.sshUsername,
                        params.sshPassword,
                        params.sshPrivateKey,
                        pendingResult!!
                    )
                } else if (pendingProxyHost != null && pendingProxyPort != null) {
                    // Regular VPN mode
                    startVpnService(
                        pendingProxyHost!!,
                        pendingProxyPort!!,
                        pendingDnsServer ?: "8.8.8.8",
                        pendingTunnelDomain ?: "",
                        pendingPublicKey ?: ""
                    )
                    pendingResult?.success(true)
                } else {
                    // Just requesting permission
                    pendingResult?.success(true)
                }
            } else {
                // Permission denied
                pendingSshVpnParams = null
                pendingSlipstreamVpnParams = null
                pendingResult?.success(false)
            }

            // Clear pending state
            pendingResult = null
            pendingProxyHost = null
            pendingProxyPort = null
            pendingDnsServer = null
            pendingTunnelDomain = null
            pendingPublicKey = null
        }
    }

    private val testScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var testPortCounter = 18000

    private fun getNextTestPort(): Int {
        synchronized(this) {
            val port = testPortCounter
            testPortCounter++
            if (testPortCounter > 19000) {
                testPortCounter = 18000
            }
            return port
        }
    }

    private fun safeStopClient(client: mobile.DnsttClient?) {
        if (client == null) return
        try {
            client.stop()
        } catch (e: Exception) {
            Log.e("DnsttTest", "Error stopping client: ${e.message}")
        }
    }

    private fun cancelAllTests() {
        Log.d("DnsttTest", "Cancelling all running tests")
        testsCancelled.set(true)

        // Cancel all running tests in background to avoid blocking main thread
        testScope.launch {
            val testsToCancel = runningTests.toMap()
            runningTests.clear()

            testsToCancel.forEach { (port, context) ->
                Log.d("DnsttTest", "Cancelling test on port $port")
                // Cancel the HTTP call first (fast)
                try {
                    context.httpCall?.cancel()
                } catch (e: Exception) {
                    Log.e("DnsttTest", "Error cancelling HTTP call: ${e.message}")
                }
                // Cancel the coroutine job
                context.job.cancel()
                // Stop the client in background (can be slow)
                launch {
                    try {
                        context.client?.stop()
                    } catch (e: Exception) {
                        Log.e("DnsttTest", "Error stopping client: ${e.message}")
                    }
                }
            }
        }
    }

    private fun testDnsServer(
        dnsServer: String,
        tunnelDomain: String,
        publicKey: String,
        testUrl: String,
        timeoutMs: Int,
        result: MethodChannel.Result
    ) {
        // Check if tests have been cancelled before starting
        if (testsCancelled.get()) {
            Log.d("DnsttTest", "Test cancelled before start for DNS: $dnsServer")
            result.success(-2) // -2 indicates cancelled
            return
        }

        Log.d("DnsttTest", "Starting test for DNS: $dnsServer")
        val port = getNextTestPort()

        val job = testScope.launch {
            var dnsttClient: mobile.DnsttClient? = null
            var httpCall: Call? = null
            var resultSent = false // Track if result has been sent

            fun sendResult(value: Int) {
                if (!resultSent) {
                    resultSent = true
                    runBlocking(Dispatchers.Main) { result.success(value) }
                }
            }

            try {
                val listenAddr = "127.0.0.1:$port"
                Log.d("DnsttTest", "Using port: $port")

                // Check cancellation
                if (testsCancelled.get()) {
                    Log.d("DnsttTest", "Test cancelled for DNS: $dnsServer")
                    sendResult(-2)
                    return@launch
                }

                // Create temporary client
                dnsttClient = Mobile.newClient(dnsServer, tunnelDomain, publicKey, listenAddr)
                Log.d("DnsttTest", "Client created")

                // Update context with client
                runningTests[port]?.let {
                    runningTests[port] = it.copy(client = dnsttClient)
                }

                // Start the client
                dnsttClient.start()
                Log.d("DnsttTest", "Client started")

                // Wait a bit for TCP listener to be ready
                delay(200)

                // Check cancellation again
                if (testsCancelled.get()) {
                    Log.d("DnsttTest", "Test cancelled after client start for DNS: $dnsServer")
                    dnsttClient.stop()
                    sendResult(-2)
                    return@launch
                }

                // Make HTTP request through DNSTT tunnel using OkHttp
                val startTime = System.currentTimeMillis()
                try {
                    val proxy = Proxy(
                        Proxy.Type.SOCKS,
                        InetSocketAddress("127.0.0.1", port)
                    )

                    val httpClient = OkHttpClient.Builder()
                        .proxy(proxy)
                        .connectTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                        .readTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                        .writeTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                        .build()

                    val request = Request.Builder()
                        .url(testUrl)
                        .build()

                    Log.d("DnsttTest", "Making HTTP request to: $testUrl")
                    httpCall = httpClient.newCall(request)

                    // Update context with HTTP call
                    runningTests[port]?.let {
                        runningTests[port] = it.copy(httpCall = httpCall)
                    }

                    val response = httpCall.execute()
                    val responseCode = response.code
                    val latency = (System.currentTimeMillis() - startTime).toInt()
                    response.close()

                    Log.d("DnsttTest", "Response code: $responseCode, latency: $latency ms")

                    // Clean up
                    safeStopClient(dnsttClient)
                    dnsttClient = null
                    runningTests.remove(port)

                    if (responseCode in 200..399) {
                        Log.d("DnsttTest", "Test SUCCESS for $dnsServer")
                        sendResult(latency)
                    } else {
                        Log.d("DnsttTest", "Test FAILED for $dnsServer - bad response code")
                        sendResult(-1)
                    }
                } catch (e: java.io.IOException) {
                    // IOException can indicate cancellation
                    if (testsCancelled.get()) {
                        Log.d("DnsttTest", "Test cancelled during HTTP request for $dnsServer")
                        safeStopClient(dnsttClient)
                        runningTests.remove(port)
                        sendResult(-2)
                    } else {
                        Log.e("DnsttTest", "HTTP request failed: ${e.message}", e)
                        safeStopClient(dnsttClient)
                        dnsttClient = null
                        runningTests.remove(port)
                        sendResult(-1)
                    }
                } catch (e: Exception) {
                    Log.e("DnsttTest", "HTTP request failed: ${e.message}", e)
                    safeStopClient(dnsttClient)
                    dnsttClient = null
                    runningTests.remove(port)
                    sendResult(-1)
                }
            } catch (e: CancellationException) {
                Log.d("DnsttTest", "Test coroutine cancelled for $dnsServer")
                safeStopClient(dnsttClient)
                runningTests.remove(port)
                sendResult(-2)
            } catch (e: Exception) {
                Log.e("DnsttTest", "Test failed: ${e.message}", e)
                safeStopClient(dnsttClient)
                runningTests.remove(port)
                sendResult(-1)
            }
        }

        // Track this test
        runningTests[port] = TestContext(job, null, null)
    }

    override fun onDestroy() {
        testScope.cancel()
        proxyScope.cancel()
        // Stop SSH tunnel client if running
        try {
            sshTunnelClient?.cleanup()
            sshTunnelClient = null
            isSshTunnelRunning.set(false)
        } catch (e: Exception) {
            Log.e("DnsttSsh", "Error stopping SSH tunnel on destroy: ${e.message}")
        }
        // Stop proxy service if running
        if (DnsttProxyService.isRunning.get()) {
            try {
                val serviceIntent = Intent(this, DnsttProxyService::class.java).apply {
                    action = DnsttProxyService.ACTION_DISCONNECT
                }
                startService(serviceIntent)
            } catch (e: Exception) {
                Log.e("DnsttProxy", "Error stopping proxy service on destroy: ${e.message}")
            }
        }
        // Stop slipstream proxy service if running
        if (SlipstreamProxyService.isRunning.get()) {
            try {
                val serviceIntent = Intent(this, SlipstreamProxyService::class.java).apply {
                    action = SlipstreamProxyService.ACTION_DISCONNECT
                }
                startService(serviceIntent)
            } catch (e: Exception) {
                Log.e("SlipstreamProxy", "Error stopping slipstream proxy on destroy: ${e.message}")
            }
        }
        DnsttProxyService.stateCallback = null
        SlipstreamProxyService.stateCallback = null
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        DnsttVpnService.stateCallback = null
        super.onDestroy()
    }
}
