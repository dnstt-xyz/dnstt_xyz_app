package xyz.dnstt.app

import android.util.Log
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

class Socks5Client(
    private val proxyHost: String,
    private val proxyPort: Int,
    private val targetHost: String,
    private val targetPort: Int,
    private val username: String? = null,
    private val password: String? = null
) {

    companion object {
        private const val TAG = "Socks5Client"
        private const val SOCKS_VERSION = 5
        private const val AUTH_METHOD_NONE = 0
        private const val AUTH_METHOD_USERNAME = 2
        private const val CMD_CONNECT = 1
        private const val ADDR_TYPE_IPV4 = 1
        private const val ADDR_TYPE_DOMAIN = 3
    }

    private val requiresAuth: Boolean get() = !username.isNullOrEmpty() && !password.isNullOrEmpty()

    private var socket: Socket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null

    var onDataReceived: ((ByteArray) -> Unit)? = null

    fun connect(): Boolean {
        try {
            shouldRun = true
            socket = Socket()
            socket?.connect(InetSocketAddress(proxyHost, proxyPort), 10000) // 10 sec connect timeout
            socket?.soTimeout = 15000 // 15 sec timeout for handshake phase
            socket?.tcpNoDelay = true // Disable Nagle for lower latency
            inputStream = socket?.getInputStream()
            outputStream = socket?.getOutputStream()

            if (!handshake()) {
                Log.e(TAG, "SOCKS5 handshake failed")
                disconnect()
                return false
            }

            if (!sendCommand()) {
                Log.e(TAG, "SOCKS5 command failed")
                disconnect()
                return false
            }
            
            Log.d(TAG, "SOCKS5 connection established")

            // Increase timeout for data phase (handshake is done)
            socket?.soTimeout = 30000 // 30 sec read timeout for data

            // Start reading from the socket in a background thread
            Thread { readLoop() }.start()

            return true

        } catch (e: IOException) {
            Log.e(TAG, "Failed to connect to SOCKS5 proxy", e)
            disconnect()
            return false
        }
    }

    private fun handshake(): Boolean {
        try {
            // Send greeting with supported auth methods
            val greeting = if (requiresAuth) {
                byteArrayOf(SOCKS_VERSION.toByte(), 2, AUTH_METHOD_NONE.toByte(), AUTH_METHOD_USERNAME.toByte())
            } else {
                byteArrayOf(SOCKS_VERSION.toByte(), 1, AUTH_METHOD_NONE.toByte())
            }
            outputStream?.write(greeting)
            outputStream?.flush()

            // Receive response
            val response = ByteArray(2)
            val bytesRead = inputStream?.read(response) ?: -1
            if (bytesRead != 2 || response[0] != SOCKS_VERSION.toByte()) {
                Log.e(TAG, "Invalid SOCKS5 greeting response")
                return false
            }

            val selectedMethod = response[1].toInt() and 0xFF
            Log.d(TAG, "Server selected auth method: $selectedMethod")

            when (selectedMethod) {
                AUTH_METHOD_NONE -> {
                    // No authentication required
                    return true
                }
                AUTH_METHOD_USERNAME -> {
                    // Username/password authentication required
                    if (!requiresAuth) {
                        Log.e(TAG, "Server requires auth but no credentials provided")
                        return false
                    }
                    return authenticateWithPassword()
                }
                0xFF -> {
                    Log.e(TAG, "Server rejected all auth methods")
                    return false
                }
                else -> {
                    Log.e(TAG, "Unsupported auth method: $selectedMethod")
                    return false
                }
            }
        } catch (e: IOException) {
            Log.e(TAG, "Handshake failed", e)
            return false
        }
    }

    private fun authenticateWithPassword(): Boolean {
        try {
            val usernameBytes = username!!.toByteArray()
            val passwordBytes = password!!.toByteArray()

            // Build auth request: VER(1) | ULEN(1) | UNAME(1-255) | PLEN(1) | PASSWD(1-255)
            val authRequest = ByteArray(3 + usernameBytes.size + passwordBytes.size)
            authRequest[0] = 0x01 // Auth sub-negotiation version
            authRequest[1] = usernameBytes.size.toByte()
            System.arraycopy(usernameBytes, 0, authRequest, 2, usernameBytes.size)
            authRequest[2 + usernameBytes.size] = passwordBytes.size.toByte()
            System.arraycopy(passwordBytes, 0, authRequest, 3 + usernameBytes.size, passwordBytes.size)

            outputStream?.write(authRequest)
            outputStream?.flush()

            // Read auth response: VER(1) | STATUS(1)
            val authResponse = ByteArray(2)
            val bytesRead = inputStream?.read(authResponse) ?: -1
            if (bytesRead != 2) {
                Log.e(TAG, "Invalid auth response length")
                return false
            }

            if (authResponse[1] != 0x00.toByte()) {
                Log.e(TAG, "Authentication failed: status=${authResponse[1]}")
                return false
            }

            Log.d(TAG, "SOCKS5 authentication successful")
            return true
        } catch (e: IOException) {
            Log.e(TAG, "Authentication failed", e)
            return false
        }
    }

    private fun sendCommand(): Boolean {
        try {
            // Build connect request
            val request = mutableListOf<Byte>()
            request.add(SOCKS_VERSION.toByte())
            request.add(CMD_CONNECT.toByte())
            request.add(0) // Reserved

            // Use domain name for target host
            request.add(ADDR_TYPE_DOMAIN.toByte())
            request.add(targetHost.length.toByte())
            request.addAll(targetHost.toByteArray().toList())

            // Port
            request.add((targetPort shr 8).toByte())
            request.add((targetPort and 0xFF).toByte())
            
            outputStream?.write(request.toByteArray())
            outputStream?.flush()

            // Receive command response
            val response = ByteArray(10) // Can be variable size
            val bytesRead = inputStream?.read(response) ?: -1
            
            // Basic validation
            if (bytesRead < 4 || response[0] != SOCKS_VERSION.toByte() || response[1] != 0.toByte()) {
                Log.e(TAG, "SOCKS5 command response invalid")
                return false
            }

            return true

        } catch (e: IOException) {
            Log.e(TAG, "Failed to send command", e)
            return false
        }
    }

    fun send(data: ByteArray) {
        try {
            outputStream?.write(data)
            outputStream?.flush()
        } catch (e: IOException) {
            Log.e(TAG, "Failed to send data", e)
            disconnect()
        }
    }

    @Volatile
    private var shouldRun = true

    private fun readLoop() {
        val buffer = ByteArray(32767)
        try {
            while (shouldRun && socket?.isConnected == true && !socket!!.isClosed) {
                val bytesRead = inputStream?.read(buffer) ?: -1
                if (bytesRead > 0) {
                    onDataReceived?.invoke(buffer.copyOf(bytesRead))
                } else if (bytesRead == -1) {
                    break // End of stream
                }
            }
        } catch (e: IOException) {
            // Only log if we weren't intentionally stopped
            if (shouldRun && socket?.isClosed == false) {
               Log.e(TAG, "Read loop error", e)
            }
        } finally {
            disconnect()
        }
    }

    fun disconnect() {
        shouldRun = false
        try {
            inputStream?.close()
            outputStream?.close()
            socket?.close()
        } catch (e: IOException) {
            // Ignore
        }
        socket = null
        inputStream = null
        outputStream = null
    }
}
