package xyz.dnstt.app

import android.util.Log
import java.io.FileOutputStream
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicLong

/**
 * Manages TCP state for a single connection through the VPN
 */
class TcpConnection(
    val sourceIp: InetAddress,
    val sourcePort: Int,
    val destIp: InetAddress,
    val destPort: Int,
    private val vpnOutput: FileOutputStream,
    private val socks5Client: Socks5Client
) {
    companion object {
        private const val TAG = "TcpConnection"
        private const val INITIAL_SEQ = 1000L
    }

    // Our sequence number (what we've sent to the client)
    private val ourSeq = AtomicLong(INITIAL_SEQ)

    // Client's sequence number (what we've received from the client)
    private var clientSeq: Long = 0

    // Initial client sequence from SYN
    private var clientInitialSeq: Long = 0

    // State tracking
    enum class State { SYN_RECEIVED, ESTABLISHED, FIN_WAIT, CLOSED }
    @Volatile
    var state = State.SYN_RECEIVED

    private val outputLock = Any()

    fun handleSyn(clientSeqNum: Long): Boolean {
        clientInitialSeq = clientSeqNum
        clientSeq = clientSeqNum + 1  // After SYN, next expected is seq+1

        // Set up data receive callback
        socks5Client.onDataReceived = { data ->
            sendDataToClient(data)
        }

        // Connect to SOCKS5 proxy
        if (!socks5Client.connect()) {
            Log.e(TAG, "Failed to connect to SOCKS5 proxy")
            return false
        }

        // Send SYN-ACK
        sendSynAck()
        return true
    }

    fun handleAck(seqNum: Long, ackNum: Long, payload: ByteArray) {
        when (state) {
            State.SYN_RECEIVED -> {
                // This is the ACK of our SYN-ACK, connection established
                if (ackNum == ourSeq.get() + 1) {
                    ourSeq.incrementAndGet()  // SYN consumed 1 seq
                    state = State.ESTABLISHED
                    Log.d(TAG, "Connection established")
                }
            }
            State.ESTABLISHED -> {
                // Data packet
                if (payload.isNotEmpty()) {
                    // Forward data to SOCKS5 proxy
                    socks5Client.send(payload)

                    // Update expected client sequence
                    clientSeq = seqNum + payload.size

                    // Send ACK for received data
                    sendAck()
                }
            }
            else -> {}
        }
    }

    fun handleFin(seqNum: Long) {
        state = State.FIN_WAIT
        clientSeq = seqNum + 1

        // Send FIN-ACK
        sendFinAck()

        // Close the SOCKS5 connection
        socks5Client.disconnect()
        state = State.CLOSED
    }

    private fun sendSynAck() {
        val tcpHeader = TCPHeader(
            sourcePort = destPort,
            destinationPort = sourcePort,
            sequenceNumber = ourSeq.get(),
            acknowledgmentNumber = clientSeq,
            dataOffset = 5,
            flags = TCPHeader.FLAG_SYN or TCPHeader.FLAG_ACK,
            windowSize = 65535,
            checksum = 0,
            urgentPointer = 0,
            payload = ByteArray(0)
        )

        sendTcpPacket(tcpHeader, ByteArray(0))
    }

    private fun sendAck() {
        val tcpHeader = TCPHeader(
            sourcePort = destPort,
            destinationPort = sourcePort,
            sequenceNumber = ourSeq.get(),
            acknowledgmentNumber = clientSeq,
            dataOffset = 5,
            flags = TCPHeader.FLAG_ACK,
            windowSize = 65535,
            checksum = 0,
            urgentPointer = 0,
            payload = ByteArray(0)
        )

        sendTcpPacket(tcpHeader, ByteArray(0))
    }

    private fun sendDataToClient(data: ByteArray) {
        if (state != State.ESTABLISHED) return

        val tcpHeader = TCPHeader(
            sourcePort = destPort,
            destinationPort = sourcePort,
            sequenceNumber = ourSeq.get(),
            acknowledgmentNumber = clientSeq,
            dataOffset = 5,
            flags = TCPHeader.FLAG_ACK or TCPHeader.FLAG_PSH,
            windowSize = 65535,
            checksum = 0,
            urgentPointer = 0,
            payload = data
        )

        sendTcpPacket(tcpHeader, data)

        // Update our sequence number
        ourSeq.addAndGet(data.size.toLong())
    }

    private fun sendFinAck() {
        val tcpHeader = TCPHeader(
            sourcePort = destPort,
            destinationPort = sourcePort,
            sequenceNumber = ourSeq.get(),
            acknowledgmentNumber = clientSeq,
            dataOffset = 5,
            flags = TCPHeader.FLAG_FIN or TCPHeader.FLAG_ACK,
            windowSize = 65535,
            checksum = 0,
            urgentPointer = 0,
            payload = ByteArray(0)
        )

        sendTcpPacket(tcpHeader, ByteArray(0))
        ourSeq.incrementAndGet()  // FIN consumes 1 seq
    }

    private fun sendTcpPacket(tcpHeader: TCPHeader, payload: ByteArray) {
        val ipHeader = IPv4Header(
            version = 4,
            ihl = 5,
            totalLength = 20 + 20 + payload.size,
            identification = (System.currentTimeMillis() and 0xFFFF).toInt(),
            flags = 0,
            fragmentOffset = 0,
            ttl = 64,
            protocol = 6,
            headerChecksum = 0,
            sourceIp = destIp,
            destinationIp = sourceIp,
            payload = ByteArray(0)
        )

        val packet = ipHeader.buildPacket(tcpHeader)

        synchronized(outputLock) {
            try {
                vpnOutput.write(packet)
                vpnOutput.flush()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to write packet", e)
            }
        }
    }

    fun close() {
        socks5Client.disconnect()
        state = State.CLOSED
    }
}
