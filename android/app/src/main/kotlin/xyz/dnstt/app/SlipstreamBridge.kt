package xyz.dnstt.app

import android.content.Context
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader

/**
 * Manages the slipstream-client binary as a subprocess on Android.
 * The binary is bundled as libslipstream_client.so in jniLibs and
 * executed from the native library directory.
 *
 * This follows the same subprocess pattern as the desktop SlipstreamService.
 */
class SlipstreamBridge {

    companion object {
        const val TAG = "SlipstreamBridge"
        private var binaryPath: String? = null

        /**
         * Initialize with application context to find the binary path.
         * Call this once from Application.onCreate() or MainActivity.
         */
        fun init(context: Context) {
            val nativeLibDir = context.applicationInfo.nativeLibraryDir
            val binary = File(nativeLibDir, "libslipstream_client.so")
            if (binary.exists() && binary.canExecute()) {
                binaryPath = binary.absolutePath
                Log.d(TAG, "slipstream-client binary found at: $binaryPath")
            } else {
                Log.w(TAG, "slipstream-client binary not found at: ${binary.absolutePath}")
                binaryPath = null
            }
        }

        fun isAvailable(): Boolean = binaryPath != null
    }

    private var process: Process? = null
    private var stderrThread: Thread? = null

    var lastError: String? = null
        private set

    /**
     * Start the slipstream-client subprocess.
     *
     * @param domain Tunnel domain (e.g., "tunnel.example.com")
     * @param dnsServer DNS server address used as resolver (from DNS server list)
     * @param congestionControl "bbr" or "dcubic" (default "dcubic")
     * @param keepAliveInterval Keep-alive interval in ms (default 400)
     * @param port Local TCP listen port
     * @param host Local listen host (e.g., "127.0.0.1")
     * @param gso Enable Generic Segmentation Offload
     * @return true if started successfully
     */
    fun startClient(
        domain: String,
        dnsServer: String,
        congestionControl: String = "dcubic",
        keepAliveInterval: Int = 400,
        port: Int = 7000,
        host: String = "127.0.0.1",
        gso: Boolean = false
    ): Boolean {
        val binary = binaryPath
        if (binary == null) {
            lastError = "slipstream-client binary not found"
            return false
        }

        if (process != null) {
            lastError = "Client already running"
            return false
        }

        lastError = null

        return try {
            val args = mutableListOf(
                binary,
                "--tcp-listen-port", port.toString(),
                "--tcp-listen-host", host,
                "--domain", domain,
                "--resolver", "$dnsServer:53",
                "--congestion-control", congestionControl,
                "--keep-alive-interval", keepAliveInterval.toString()
            )

            if (gso) {
                args.add("--gso")
            }

            Log.d(TAG, "Starting: ${args.joinToString(" ")}")

            val pb = ProcessBuilder(args)
            pb.redirectErrorStream(false)
            process = pb.start()

            // Monitor stderr for errors
            stderrThread = Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(process!!.errorStream))
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        Log.d(TAG, "stderr: $line")
                        val l = line!!.lowercase()
                        if (l.contains("error") || l.contains("fatal") || l.contains("panic")) {
                            lastError = line
                        }
                    }
                } catch (e: Exception) {
                    // Process closed
                }
            }.also { it.isDaemon = true; it.start() }

            // Wait a moment for the process to start or fail
            Thread.sleep(1500)

            // Check if process is still alive
            if (!isRunning()) {
                val exitCode = try { process!!.exitValue() } catch (e: Exception) { -1 }
                lastError = "slipstream-client exited immediately with code: $exitCode"
                process = null
                stderrThread = null
                Log.e(TAG, "Process exited: $lastError")
                false
            } else {
                Log.d(TAG, "slipstream-client started successfully on port $port")
                true
            }
        } catch (e: Exception) {
            lastError = e.message
            process = null
            stderrThread = null
            Log.e(TAG, "Failed to start slipstream-client: ${e.message}", e)
            false
        }
    }

    /**
     * Stop the running slipstream-client subprocess.
     */
    fun stopClient() {
        try {
            process?.destroy()
            // Give it a moment to exit gracefully
            Thread.sleep(200)
            // Force kill if still alive
            if (isRunning()) {
                process?.destroyForcibly()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping slipstream-client: ${e.message}", e)
        }
        process = null
        stderrThread = null
    }

    /**
     * Check if the slipstream-client process is running.
     */
    fun isRunning(): Boolean {
        val p = process ?: return false
        return try {
            p.exitValue()
            // If exitValue() returns without throwing, process has exited
            false
        } catch (e: IllegalThreadStateException) {
            // Process is still running
            true
        }
    }
}
