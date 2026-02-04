import 'dart:async';
import 'dart:io';

/// Manages the slipstream-client binary as a subprocess on desktop platforms.
/// Slipstream uses QUIC-over-DNS and is significantly faster than DNSTT.
///
/// The slipstream-client binary provides a local SOCKS5 proxy, same as DNSTT.
/// DNS resolvers come from the DNS server list (same as DNSTT).
class SlipstreamService {
  static SlipstreamService? _instance;
  static SlipstreamService get instance => _instance ??= SlipstreamService._();

  SlipstreamService._();

  Process? _process;
  String? _lastError;
  bool _isRunning = false;

  bool get isRunning => _isRunning;
  String? get lastError => _lastError;

  /// Find the slipstream-client binary for the current platform.
  String? _findBinaryPath() {
    final executablePath = Platform.resolvedExecutable;
    print('SlipstreamService: resolvedExecutable = $executablePath');
    final List<String> paths;

    if (Platform.isMacOS) {
      final bundlePath = executablePath.contains('/Contents/MacOS/')
          ? executablePath.substring(0, executablePath.indexOf('/Contents/MacOS/'))
          : executablePath;
      final contentsPath = '$bundlePath/Contents';
      paths = [
        '$contentsPath/Frameworks/slipstream-client',
        '$contentsPath/MacOS/slipstream-client',
        '$contentsPath/Resources/slipstream-client',
        '${Directory.current.path}/macos/Runner/Libraries/slipstream-client',
        '${Directory.current.path}/slipstream-client',
        'slipstream-client',
      ];
    } else if (Platform.isWindows) {
      final executableDir = File(executablePath).parent.path;
      paths = [
        '$executableDir\\slipstream-client.exe',
        '${Directory.current.path}\\slipstream-client.exe',
        'slipstream-client.exe',
      ];
    } else if (Platform.isLinux) {
      final executableDir = File(executablePath).parent.path;
      paths = [
        '$executableDir/lib/slipstream-client',
        '$executableDir/slipstream-client',
        '${Directory.current.path}/slipstream-client',
        'slipstream-client',
      ];
    } else {
      return null;
    }

    for (final path in paths) {
      final exists = File(path).existsSync();
      print('SlipstreamService: checking $path -> $exists');
      if (exists) {
        return path;
      }
    }

    // Try PATH lookup as fallback
    print('SlipstreamService: binary not found in known paths, falling back to PATH lookup');
    return 'slipstream-client';
  }

  /// Start the slipstream-client subprocess.
  ///
  /// [domain] - Tunnel domain (e.g., "tunnel.example.com")
  /// [dnsServerAddr] - DNS server address used as resolver (from DNS server list)
  /// [listenPort] - Local SOCKS5 proxy port (default 7000)
  /// [congestionControl] - "bbr" or "dcubic" (default "dcubic")
  /// [keepAliveInterval] - Keep-alive interval in ms (default 400)
  /// [gso] - Enable Generic Segmentation Offload (default false)
  Future<bool> startClient({
    required String domain,
    required String dnsServerAddr,
    int listenPort = 7000,
    String congestionControl = 'dcubic',
    int keepAliveInterval = 400,
    bool gso = false,
  }) async {
    if (_isRunning) {
      _lastError = 'Client already running';
      return false;
    }

    final binaryPath = _findBinaryPath();
    if (binaryPath == null) {
      _lastError = 'slipstream-client binary not found';
      return false;
    }

    _lastError = null;

    try {
      final args = [
        '--tcp-listen-port', listenPort.toString(),
        '--domain', domain,
        '--resolver', '$dnsServerAddr:53',
        '--congestion-control', congestionControl,
        '--keep-alive-interval', keepAliveInterval.toString(),
      ];

      if (gso) {
        args.add('--gso');
      }

      print('Starting slipstream-client: $binaryPath ${args.join(' ')}');

      _process = await Process.start(binaryPath, args);

      // Monitor stderr for errors
      _process!.stderr.listen((data) {
        final output = String.fromCharCodes(data);
        print('slipstream-client stderr: $output');
        if (output.toLowerCase().contains('error') ||
            output.toLowerCase().contains('fatal')) {
          _lastError = output.trim();
        }
      });

      _process!.stdout.listen((data) {
        print('slipstream-client stdout: ${String.fromCharCodes(data)}');
      });

      // Monitor process exit
      _process!.exitCode.then((code) {
        print('slipstream-client exited with code: $code');
        _isRunning = false;
        if (code != 0) {
          _lastError = 'slipstream-client exited with code $code';
        }
      });

      // Wait for the proxy to be ready
      await Future.delayed(const Duration(seconds: 1));

      // Verify the process is still running
      final exitCodeFuture = _process!.exitCode;
      final result = await Future.any([
        exitCodeFuture.then((code) => 'exited:$code'),
        Future.delayed(const Duration(milliseconds: 500), () => 'running'),
      ]);

      if (result.startsWith('exited')) {
        final code = result.split(':')[1];
        _lastError = 'slipstream-client failed to start (exit code: $code)';
        _isRunning = false;
        _process = null;
        return false;
      }

      _isRunning = true;
      return true;
    } catch (e) {
      _lastError = e.toString();
      _isRunning = false;
      _process = null;
      return false;
    }
  }

  /// Stop the running slipstream-client subprocess.
  Future<void> stopClient() async {
    if (_process != null) {
      _process!.kill();
      _process = null;
    }
    _isRunning = false;
  }

  /// Test a slipstream server by spawning a temporary slipstream-client,
  /// making an HTTP request through the SOCKS5 proxy, and returning the latency.
  ///
  /// Returns latency in milliseconds on success, -1 on failure.
  Future<int> testServer({
    required String domain,
    required String dnsServerAddr,
    int listenPort = 18500,
    String testUrl = 'https://api.ipify.org?format=json',
    int timeoutMs = 15000,
    String congestionControl = 'dcubic',
    int keepAliveInterval = 400,
    bool gso = false,
  }) async {
    final binaryPath = _findBinaryPath();
    if (binaryPath == null) {
      return -1;
    }

    Process? testProcess;
    try {
      final args = [
        '--tcp-listen-port', listenPort.toString(),
        '--domain', domain,
        '--resolver', '$dnsServerAddr:53',
        '--congestion-control', congestionControl,
        '--keep-alive-interval', keepAliveInterval.toString(),
      ];

      if (gso) {
        args.add('--gso');
      }

      testProcess = await Process.start(binaryPath, args);

      // Wait for the proxy to be ready
      await Future.delayed(const Duration(seconds: 2));

      // Check if process is still running
      final checkResult = await Future.any([
        testProcess.exitCode.then((code) => 'exited:$code'),
        Future.delayed(const Duration(milliseconds: 300), () => 'running'),
      ]);

      if (checkResult.startsWith('exited')) {
        return -1;
      }

      // Make HTTP request through the SOCKS5 proxy
      final stopwatch = Stopwatch()..start();
      final uri = Uri.parse(testUrl);
      final client = HttpClient();
      client.connectionTimeout = Duration(milliseconds: timeoutMs);
      client.findProxy = (uri) => 'SOCKS5 127.0.0.1:$listenPort';

      try {
        final request = await client.getUrl(uri).timeout(
          Duration(milliseconds: timeoutMs),
        );
        final response = await request.close().timeout(
          Duration(milliseconds: timeoutMs),
        );
        stopwatch.stop();
        client.close();

        if (response.statusCode >= 200 && response.statusCode < 400) {
          return stopwatch.elapsedMilliseconds;
        }
        return -1;
      } on TimeoutException {
        client.close();
        return -1;
      } catch (e) {
        client.close();
        return -1;
      }
    } catch (e) {
      print('Slipstream test error: $e');
      return -1;
    } finally {
      testProcess?.kill();
    }
  }
}
