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
    private val targetPort: Int
) {

    companion object {
        private const val TAG = "Socks5Client"
        private const val SOCKS_VERSION = 5
        private const val AUTH_METHOD_NONE = 0
        private const val CMD_CONNECT = 1
        private const val ADDR_TYPE_IPV4 = 1
        private const val ADDR_TYPE_DOMAIN = 3
    }

    private var socket: Socket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null

    var onDataReceived: ((ByteArray) -> Unit)? = null

    fun connect(): Boolean {
        try {
            shouldRun = true
            socket = Socket()
            socket?.connect(InetSocketAddress(proxyHost, proxyPort), 30000) // 30 sec timeout for dnstt
            socket?.soTimeout = 60000 // 60 sec read timeout
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
            // Send greeting
            val greeting = byteArrayOf(SOCKS_VERSION.toByte(), 1, AUTH_METHOD_NONE.toByte())
            outputStream?.write(greeting)
            outputStream?.flush()

            // Receive response
            val response = ByteArray(2)
            val bytesRead = inputStream?.read(response) ?: -1
            if (bytesRead != 2 || response[0] != SOCKS_VERSION.toByte() || response[1] != AUTH_METHOD_NONE.toByte()) {
                return false
            }
            return true
        } catch (e: IOException) {
            Log.e(TAG, "Handshake failed", e)
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
