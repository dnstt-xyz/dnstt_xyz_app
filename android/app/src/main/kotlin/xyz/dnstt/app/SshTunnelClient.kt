package xyz.dnstt.app

import android.util.Log
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import com.jcraft.jsch.ChannelDirectTCPIP
import kotlinx.coroutines.*
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Properties
import java.util.concurrent.atomic.AtomicBoolean

/**
 * SSH Tunnel Client that creates a local SOCKS5 proxy through SSH dynamic port forwarding.
 *
 * Flow:
 * 1. DNSTT creates TCP tunnel to SSH server (127.0.0.1:7000 -> SSH server port 22)
 * 2. This SSH client connects to 127.0.0.1:7000 (which is the SSH server through DNSTT)
 * 3. Sets up SSH dynamic port forwarding (-D equivalent)
 * 4. Creates local SOCKS5 proxy on specified port (e.g., 1080)
 * 5. User apps connect to 127.0.0.1:1080 for proxied internet access
 */
class SshTunnelClient {
    companion object {
        private const val TAG = "SshTunnelClient"

        // DNSTT tunnel endpoint - SSH server is accessible through this internal port
        private const val DNSTT_TUNNEL_HOST = "127.0.0.1"
        private const val DNSTT_TUNNEL_PORT = 7001

        // SOCKS5 proxy output port (same as other modes)
        private const val SOCKS5_PROXY_PORT = 1080
    }

    private var session: Session? = null
    private var socksServerSocket: ServerSocket? = null
    private var isRunning = AtomicBoolean(false)
    private var socksJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var shareProxyEnabled = false

    var lastError: String? = null
        private set

    /**
     * Connect to SSH server through DNSTT tunnel and start SOCKS5 proxy on port 1080.
     *
     * @param username SSH username
     * @param password SSH password (optional if using key)
     * @param privateKey SSH private key in OpenSSH format (optional if using password)
     * @param shareProxy If true, bind to 0.0.0.0 to allow network access; if false, bind to 127.0.0.1
     * @return true if connection successful
     */
    suspend fun connect(
        username: String,
        password: String? = null,
        privateKey: String? = null,
        shareProxy: Boolean = false
    ): Boolean = withContext(Dispatchers.IO) {
        shareProxyEnabled = shareProxy
        try {
            if (isRunning.get()) {
                Log.w(TAG, "SSH tunnel already running")
                return@withContext true
            }

            lastError = null
            Log.i(TAG, "Connecting SSH through DNSTT tunnel at $DNSTT_TUNNEL_HOST:$DNSTT_TUNNEL_PORT")

            val jsch = JSch()

            // Add private key if provided
            if (!privateKey.isNullOrEmpty()) {
                try {
                    jsch.addIdentity("dnstt_key", privateKey.toByteArray(), null, null)
                    Log.d(TAG, "Added SSH private key")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to add private key: ${e.message}")
                }
            }

            // Create session connecting THROUGH the DNSTT tunnel
            // The DNSTT tunnel (127.0.0.1:7000) forwards to the SSH server
            session = jsch.getSession(username, DNSTT_TUNNEL_HOST, DNSTT_TUNNEL_PORT).apply {
                // Set password if provided
                if (!password.isNullOrEmpty()) {
                    setPassword(password)
                }

                // Configure session
                val config = Properties().apply {
                    put("StrictHostKeyChecking", "no")
                    put("PreferredAuthentications", "publickey,password,keyboard-interactive")
                    put("compression.s2c", "none")
                    put("compression.c2s", "none")
                }
                setConfig(config)

                // Set timeouts
                timeout = 30000 // 30 seconds connection timeout
                setServerAliveInterval(15000) // Keep-alive every 15 seconds
                setServerAliveCountMax(3)
            }

            Log.i(TAG, "Attempting SSH connection as user '$username'...")
            session?.connect(30000)

            if (session?.isConnected != true) {
                lastError = "SSH session failed to connect"
                Log.e(TAG, lastError!!)
                return@withContext false
            }

            Log.i(TAG, "SSH session connected successfully")

            // Start local SOCKS5 proxy with dynamic port forwarding on port 7000
            startSocksProxy(SOCKS5_PROXY_PORT)

            isRunning.set(true)
            Log.i(TAG, "SSH tunnel with SOCKS5 proxy started on port $SOCKS5_PROXY_PORT")

            true
        } catch (e: Exception) {
            lastError = e.message ?: "Unknown SSH error"
            Log.e(TAG, "SSH connection failed: $lastError", e)
            disconnect()
            false
        }
    }

    /**
     * Start local SOCKS5 proxy server that forwards through SSH.
     */
    private fun startSocksProxy(port: Int) {
        // Bind to 0.0.0.0 if sharing is enabled, otherwise bind to localhost only
        val bindAddress = if (shareProxyEnabled) {
            InetSocketAddress(InetAddress.getByName("0.0.0.0"), port)
        } else {
            InetSocketAddress(InetAddress.getByName("127.0.0.1"), port)
        }

        socksServerSocket = ServerSocket().apply {
            reuseAddress = true
            bind(bindAddress)
        }

        Log.i(TAG, "SOCKS5 proxy binding to ${bindAddress.address.hostAddress}:$port (sharing: $shareProxyEnabled)")

        socksJob = scope.launch {
            Log.i(TAG, "SOCKS5 proxy listening on port $port")

            while (isActive && isRunning.get()) {
                try {
                    val clientSocket = socksServerSocket?.accept() ?: break

                    launch {
                        handleSocksClient(clientSocket)
                    }
                } catch (e: IOException) {
                    if (isRunning.get()) {
                        Log.e(TAG, "Error accepting SOCKS connection: ${e.message}")
                    }
                    break
                }
            }
        }
    }

    /**
     * Handle SOCKS5 client connection.
     */
    private suspend fun handleSocksClient(clientSocket: Socket) = withContext(Dispatchers.IO) {
        try {
            val input = clientSocket.getInputStream()
            val output = clientSocket.getOutputStream()

            // SOCKS5 greeting
            val greeting = ByteArray(256)
            val greetingLen = input.read(greeting)

            if (greetingLen < 2 || greeting[0] != 0x05.toByte()) {
                Log.w(TAG, "Invalid SOCKS5 greeting")
                clientSocket.close()
                return@withContext
            }

            // Send no-auth response
            output.write(byteArrayOf(0x05, 0x00))
            output.flush()

            // Read connection request
            val request = ByteArray(256)
            val requestLen = input.read(request)

            if (requestLen < 4 || request[0] != 0x05.toByte() || request[1] != 0x01.toByte()) {
                Log.w(TAG, "Invalid SOCKS5 request")
                clientSocket.close()
                return@withContext
            }

            // Parse destination
            val (host, port) = when (request[3].toInt() and 0xFF) {
                0x01 -> { // IPv4
                    val addr = "${request[4].toInt() and 0xFF}.${request[5].toInt() and 0xFF}.${request[6].toInt() and 0xFF}.${request[7].toInt() and 0xFF}"
                    val p = ((request[8].toInt() and 0xFF) shl 8) or (request[9].toInt() and 0xFF)
                    Pair(addr, p)
                }
                0x03 -> { // Domain name
                    val domainLen = request[4].toInt() and 0xFF
                    val domain = String(request, 5, domainLen)
                    val portOffset = 5 + domainLen
                    val p = ((request[portOffset].toInt() and 0xFF) shl 8) or (request[portOffset + 1].toInt() and 0xFF)
                    Pair(domain, p)
                }
                0x04 -> { // IPv6
                    Log.w(TAG, "IPv6 not supported")
                    sendSocksError(output, 0x08) // Address type not supported
                    clientSocket.close()
                    return@withContext
                }
                else -> {
                    Log.w(TAG, "Unknown address type")
                    sendSocksError(output, 0x08)
                    clientSocket.close()
                    return@withContext
                }
            }

            Log.d(TAG, "SOCKS5 connect request to $host:$port")

            // Create SSH direct-tcpip channel to forward the connection
            try {
                val channel = session?.openChannel("direct-tcpip") as? ChannelDirectTCPIP
                if (channel == null) {
                    Log.e(TAG, "Failed to open SSH channel")
                    sendSocksError(output, 0x01)
                    clientSocket.close()
                    return@withContext
                }

                channel.setHost(host)
                channel.setPort(port)
                channel.connect(10000)

                // Send success response
                output.write(byteArrayOf(
                    0x05, 0x00, 0x00, 0x01,
                    0x00, 0x00, 0x00, 0x00, // Bind address (0.0.0.0)
                    0x00, 0x00 // Bind port (0)
                ))
                output.flush()

                // Bidirectional forwarding
                val sshInput = channel.inputStream
                val sshOutput = channel.outputStream

                val job1 = scope.launch {
                    try {
                        val buffer = ByteArray(8192)
                        while (isActive) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            sshOutput.write(buffer, 0, read)
                            sshOutput.flush()
                        }
                    } catch (e: Exception) {
                        // Connection closed
                    }
                }

                val job2 = scope.launch {
                    try {
                        val buffer = ByteArray(8192)
                        while (isActive) {
                            val read = sshInput.read(buffer)
                            if (read <= 0) break
                            output.write(buffer, 0, read)
                            output.flush()
                        }
                    } catch (e: Exception) {
                        // Connection closed
                    }
                }

                // Wait for either direction to complete
                job1.join()
                job2.cancel()

                channel.disconnect()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to forward to $host:$port: ${e.message}")
                sendSocksError(output, 0x01)
            }

            clientSocket.close()
        } catch (e: Exception) {
            Log.e(TAG, "SOCKS client error: ${e.message}")
            try { clientSocket.close() } catch (_: Exception) {}
        }
    }

    private fun sendSocksError(output: java.io.OutputStream, errorCode: Int) {
        try {
            output.write(byteArrayOf(
                0x05, errorCode.toByte(), 0x00, 0x01,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00
            ))
            output.flush()
        } catch (_: Exception) {}
    }

    /**
     * Disconnect SSH session and stop SOCKS5 proxy.
     */
    fun disconnect() {
        Log.i(TAG, "Disconnecting SSH tunnel")
        isRunning.set(false)

        socksJob?.cancel()
        socksJob = null

        try {
            socksServerSocket?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing SOCKS server: ${e.message}")
        }
        socksServerSocket = null

        try {
            session?.disconnect()
        } catch (e: Exception) {
            Log.e(TAG, "Error disconnecting SSH: ${e.message}")
        }
        session = null

        Log.i(TAG, "SSH tunnel disconnected")
    }

    /**
     * Check if SSH tunnel is connected.
     */
    fun isConnected(): Boolean {
        return isRunning.get() && session?.isConnected == true
    }

    /**
     * Clean up resources.
     */
    fun cleanup() {
        disconnect()
        scope.cancel()
    }
}
