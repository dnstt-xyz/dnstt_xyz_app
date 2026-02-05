import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/dns_server.dart';
import '../models/dnstt_config.dart';
import 'dnstt_ffi_service.dart';
import 'slipstream_service.dart';
import 'vpn_service.dart';

enum TestResult { success, failed, timeout }

class TunnelTestResult {
  final TestResult result;
  final String? message;
  final Duration? latency;
  final int? statusCode;

  TunnelTestResult({
    required this.result,
    this.message,
    this.latency,
    this.statusCode,
  });
}

class DnsttTestResult {
  final DnsServer server;
  final TestResult result;
  final String? message;
  final Duration? latency;

  DnsttTestResult({
    required this.server,
    required this.result,
    this.message,
    this.latency,
  });
}

class DnsttService {
  static const Duration testTimeout = Duration(seconds: 5);

  // Base32 alphabet (RFC 4648 without padding)
  static const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// Encodes bytes to base32 (no padding)
  static String _base32Encode(Uint8List data) {
    if (data.isEmpty) return '';

    final result = StringBuffer();
    int buffer = 0;
    int bitsLeft = 0;

    for (final byte in data) {
      buffer = (buffer << 8) | byte;
      bitsLeft += 8;

      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        result.write(_base32Alphabet[(buffer >> bitsLeft) & 0x1F]);
      }
    }

    if (bitsLeft > 0) {
      result.write(_base32Alphabet[(buffer << (5 - bitsLeft)) & 0x1F]);
    }

    return result.toString().toLowerCase();
  }

  /// Builds a DNSTT-style DNS TXT query for the tunnel domain
  /// This mimics what the dnstt client sends
  static Uint8List _buildDnsttQuery(String tunnelDomain) {
    final random = Random.secure();
    final transactionId = random.nextInt(65535);

    // Generate a random client ID (8 bytes) like dnstt does
    final clientId = Uint8List(8);
    for (int i = 0; i < 8; i++) {
      clientId[i] = random.nextInt(256);
    }

    // Build the payload: clientID + padding indicator + padding
    final payload = BytesBuilder();
    payload.add(clientId);
    // Padding indicator: 224 + numPadding (we use 8 for poll)
    payload.addByte(224 + 8);
    // Add 8 bytes of random padding
    for (int i = 0; i < 8; i++) {
      payload.addByte(random.nextInt(256));
    }

    // Encode payload as base32
    final encoded = _base32Encode(payload.toBytes());

    // Split into labels (max 63 chars each)
    final labels = <String>[];
    var remaining = encoded;
    while (remaining.isNotEmpty) {
      final chunkSize = remaining.length > 63 ? 63 : remaining.length;
      labels.add(remaining.substring(0, chunkSize));
      remaining = remaining.substring(chunkSize);
    }

    // Add tunnel domain labels
    final domainParts = tunnelDomain.split('.');
    labels.addAll(domainParts);

    // Build DNS query
    final query = BytesBuilder();

    // Transaction ID (2 bytes)
    query.addByte((transactionId >> 8) & 0xFF);
    query.addByte(transactionId & 0xFF);

    // Flags: standard query with RD (recursion desired)
    query.addByte(0x01);
    query.addByte(0x00);

    // Questions: 1
    query.addByte(0x00);
    query.addByte(0x01);

    // Answer RRs: 0
    query.addByte(0x00);
    query.addByte(0x00);

    // Authority RRs: 0
    query.addByte(0x00);
    query.addByte(0x00);

    // Additional RRs: 1 (for EDNS0 OPT)
    query.addByte(0x00);
    query.addByte(0x01);

    // Build QNAME from labels
    for (final label in labels) {
      query.addByte(label.length);
      query.add(utf8.encode(label));
    }
    query.addByte(0); // null terminator

    // Type: TXT (16)
    query.addByte(0x00);
    query.addByte(0x10);

    // Class: IN (1)
    query.addByte(0x00);
    query.addByte(0x01);

    // EDNS0 OPT record (for larger responses)
    query.addByte(0x00); // Name: root
    query.addByte(0x00); // Type: OPT (41)
    query.addByte(0x29);
    query.addByte(0x10); // UDP payload size: 4096
    query.addByte(0x00);
    query.addByte(0x00); // Extended RCODE
    query.addByte(0x00); // Version
    query.addByte(0x00); // Flags
    query.addByte(0x00);
    query.addByte(0x00); // RDATA length: 0
    query.addByte(0x00);

    return query.toBytes();
  }

  /// Builds a simple DNS query for google.com (for basic connectivity test)
  static Uint8List _buildSimpleDnsQuery() {
    final random = Random();
    final transactionId = random.nextInt(65535);

    // DNS query for google.com A record
    final query = BytesBuilder();

    // Transaction ID (2 bytes)
    query.addByte((transactionId >> 8) & 0xFF);
    query.addByte(transactionId & 0xFF);

    // Flags: standard query (2 bytes)
    query.addByte(0x01); // RD (recursion desired)
    query.addByte(0x00);

    // Questions: 1
    query.addByte(0x00);
    query.addByte(0x01);

    // Answer RRs: 0
    query.addByte(0x00);
    query.addByte(0x00);

    // Authority RRs: 0
    query.addByte(0x00);
    query.addByte(0x00);

    // Additional RRs: 0
    query.addByte(0x00);
    query.addByte(0x00);

    // Query: google.com
    query.addByte(6); // length of "google"
    query.add('google'.codeUnits);
    query.addByte(3); // length of "com"
    query.add('com'.codeUnits);
    query.addByte(0); // null terminator

    // Type: A (1)
    query.addByte(0x00);
    query.addByte(0x01);

    // Class: IN (1)
    query.addByte(0x00);
    query.addByte(0x01);

    return query.toBytes();
  }

  /// Check if we're on a desktop platform
  static bool get isDesktopPlatform =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Tests if a DNS server works with the tunnel (DNSTT or Slipstream)
  /// On both desktop and mobile (Android): Actually connects through the tunnel and makes HTTP request
  /// Fallback to DNS query test when no config available
  static Future<DnsttTestResult> testDnsServer(
    DnsServer server, {
    String? tunnelDomain,
    String? publicKey,
    String testUrl = 'https://api.ipify.org?format=json',
    Duration timeout = const Duration(seconds: 15),
    TransportType transportType = TransportType.dnstt,
    String congestionControl = 'dcubic',
    int keepAliveInterval = 400,
    bool gso = false,
  }) async {
    // Slipstream transport
    if (transportType == TransportType.slipstream && tunnelDomain != null) {
      return _testDnsServerViaSlipstream(
        server,
        tunnelDomain: tunnelDomain,
        testUrl: testUrl,
        timeout: timeout,
        congestionControl: congestionControl,
        keepAliveInterval: keepAliveInterval,
        gso: gso,
      );
    }

    // DNSTT transport: use real tunnel test when we have config
    if (tunnelDomain != null && publicKey != null) {
      return _testDnsServerViaTunnel(
        server,
        tunnelDomain: tunnelDomain,
        publicKey: publicKey,
        testUrl: testUrl,
        timeout: timeout,
      );
    }

    // Fallback to DNS query test when no config
    return _testDnsServerViaDnsQuery(server, tunnelDomain: tunnelDomain, timeout: timeout);
  }

  /// Test DNS server using Slipstream transport
  static Future<DnsttTestResult> _testDnsServerViaSlipstream(
    DnsServer server, {
    required String tunnelDomain,
    required String testUrl,
    required Duration timeout,
    String congestionControl = 'dcubic',
    int keepAliveInterval = 400,
    bool gso = false,
  }) async {
    if (isDesktopPlatform) {
      // Desktop: use SlipstreamService subprocess
      try {
        final result = await SlipstreamService.instance.testServer(
          domain: tunnelDomain,
          dnsServerAddr: server.address,
          testUrl: testUrl,
          timeoutMs: timeout.inMilliseconds,
          congestionControl: congestionControl,
          keepAliveInterval: keepAliveInterval,
          gso: gso,
        );

        if (result >= 0) {
          return DnsttTestResult(
            server: server,
            result: TestResult.success,
            message: 'Tunnel working',
            latency: Duration(milliseconds: result),
          );
        } else {
          return DnsttTestResult(
            server: server,
            result: TestResult.failed,
            message: 'Connection failed',
          );
        }
      } catch (e) {
        return DnsttTestResult(
          server: server,
          result: TestResult.failed,
          message: 'Error: $e',
        );
      }
    }

    // Mobile: use method channel
    try {
      final vpnService = VpnService();
      await vpnService.init();

      final result = await vpnService.testSlipstreamDnsServer(
        dnsServer: server.address,
        tunnelDomain: tunnelDomain,
        testUrl: testUrl,
        timeoutMs: timeout.inMilliseconds,
        congestionControl: congestionControl,
        keepAliveInterval: keepAliveInterval,
        gso: gso,
      );

      if (result >= 0) {
        return DnsttTestResult(
          server: server,
          result: TestResult.success,
          message: 'Tunnel working',
          latency: Duration(milliseconds: result),
        );
      } else if (result == -2) {
        return DnsttTestResult(
          server: server,
          result: TestResult.failed,
          message: 'Cancelled',
        );
      } else {
        return DnsttTestResult(
          server: server,
          result: TestResult.failed,
          message: 'Connection failed',
        );
      }
    } catch (e) {
      return DnsttTestResult(
        server: server,
        result: TestResult.failed,
        message: 'Error: $e',
      );
    }
  }

  /// Test DNS server using actual tunnel connection (works on desktop and mobile)
  static Future<DnsttTestResult> _testDnsServerViaTunnel(
    DnsServer server, {
    required String tunnelDomain,
    required String publicKey,
    required String testUrl,
    required Duration timeout,
  }) async {
    // On desktop, run the FFI test in a separate isolate to avoid blocking UI
    if (isDesktopPlatform) {
      return _testDnsServerInIsolate(
        server: server,
        tunnelDomain: tunnelDomain,
        publicKey: publicKey,
        testUrl: testUrl,
        timeoutMs: timeout.inMilliseconds,
      );
    }

    // On mobile, use method channel (already async)
    final stopwatch = Stopwatch()..start();
    try {
      final vpnService = VpnService();
      await vpnService.init();

      final result = await vpnService.testDnsServer(
        dnsServer: server.address,
        tunnelDomain: tunnelDomain,
        publicKey: publicKey,
        testUrl: testUrl,
        timeoutMs: timeout.inMilliseconds,
      );

      stopwatch.stop();

      if (result >= 0) {
        return DnsttTestResult(
          server: server,
          result: TestResult.success,
          message: 'Tunnel working',
          latency: Duration(milliseconds: result),
        );
      } else if (result == -2) {
        // Cancelled
        return DnsttTestResult(
          server: server,
          result: TestResult.failed,
          message: 'Cancelled',
        );
      } else {
        return DnsttTestResult(
          server: server,
          result: TestResult.failed,
          message: 'Connection failed',
        );
      }
    } catch (e) {
      stopwatch.stop();
      return DnsttTestResult(
        server: server,
        result: TestResult.failed,
        message: 'Error: $e',
      );
    }
  }

  /// Run the FFI test in a separate isolate to avoid blocking the UI
  static Future<DnsttTestResult> _testDnsServerInIsolate({
    required DnsServer server,
    required String tunnelDomain,
    required String publicKey,
    required String testUrl,
    required int timeoutMs,
  }) async {
    try {
      // Use compute to run in a separate isolate
      final result = await compute(_runFfiTest, {
        'dnsServer': server.address,
        'tunnelDomain': tunnelDomain,
        'publicKey': publicKey,
        'testUrl': testUrl,
        'timeoutMs': timeoutMs,
      });

      if (result >= 0) {
        return DnsttTestResult(
          server: server,
          result: TestResult.success,
          message: 'Tunnel working',
          latency: Duration(milliseconds: result),
        );
      } else {
        return DnsttTestResult(
          server: server,
          result: TestResult.failed,
          message: 'Connection failed',
        );
      }
    } catch (e) {
      return DnsttTestResult(
        server: server,
        result: TestResult.failed,
        message: 'Error: $e',
      );
    }
  }

  /// Test DNS server using DNS query (mobile fallback)
  static Future<DnsttTestResult> _testDnsServerViaDnsQuery(
    DnsServer server, {
    String? tunnelDomain,
    Duration timeout = testTimeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    RawDatagramSocket? socket;

    try {
      // Create UDP socket
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      final serverAddress = InternetAddress.tryParse(server.address);
      if (serverAddress == null) {
        stopwatch.stop();
        return DnsttTestResult(
          server: server,
          result: TestResult.failed,
          message: 'Invalid IP address',
        );
      }

      // Build DNS query - use DNSTT format if tunnel domain provided
      final Uint8List query;
      final bool isDnsttTest = tunnelDomain != null && tunnelDomain.isNotEmpty;
      if (isDnsttTest) {
        query = _buildDnsttQuery(tunnelDomain);
      } else {
        query = _buildSimpleDnsQuery();
      }

      socket.send(query, serverAddress, 53);

      // Wait for response with timeout
      final completer = Completer<DnsttTestResult>();
      Timer? timeoutTimer;

      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.complete(DnsttTestResult(
            server: server,
            result: TestResult.timeout,
            message: isDnsttTest ? 'Tunnel query timed out' : 'DNS query timed out',
          ));
        }
      });

      socket.listen((event) {
        if (event == RawSocketEvent.read && !completer.isCompleted) {
          final datagram = socket?.receive();
          if (datagram != null && datagram.data.length > 12) {
            stopwatch.stop();
            timeoutTimer?.cancel();

            // Check if it's a valid DNS response
            final flags = datagram.data[2];
            final isResponse = (flags & 0x80) != 0;

            // Check RCODE (last 4 bits of second flag byte)
            final rcode = datagram.data[3] & 0x0F;

            if (!isResponse) {
              completer.complete(DnsttTestResult(
                server: server,
                result: TestResult.failed,
                message: 'Invalid DNS response',
              ));
              return;
            }

            if (isDnsttTest) {
              // For DNSTT test, check if we got a TXT response
              // RCODE 0 = success, 3 = NXDOMAIN (domain not found)
              if (rcode == 0) {
                // Check if there's an answer section
                final answerCount = (datagram.data[6] << 8) | datagram.data[7];
                if (answerCount > 0) {
                  completer.complete(DnsttTestResult(
                    server: server,
                    result: TestResult.success,
                    message: 'Tunnel working',
                    latency: stopwatch.elapsed,
                  ));
                } else {
                  // No answer but no error - might work
                  completer.complete(DnsttTestResult(
                    server: server,
                    result: TestResult.success,
                    message: 'Tunnel reachable',
                    latency: stopwatch.elapsed,
                  ));
                }
              } else if (rcode == 3) {
                completer.complete(DnsttTestResult(
                  server: server,
                  result: TestResult.failed,
                  message: 'Domain not found (NXDOMAIN)',
                ));
              } else if (rcode == 2) {
                completer.complete(DnsttTestResult(
                  server: server,
                  result: TestResult.failed,
                  message: 'Server failure (SERVFAIL)',
                ));
              } else if (rcode == 5) {
                completer.complete(DnsttTestResult(
                  server: server,
                  result: TestResult.failed,
                  message: 'Query refused',
                ));
              } else {
                completer.complete(DnsttTestResult(
                  server: server,
                  result: TestResult.failed,
                  message: 'DNS error (RCODE: $rcode)',
                ));
              }
            } else {
              // Simple DNS test - just check for response
              if (rcode == 0) {
                completer.complete(DnsttTestResult(
                  server: server,
                  result: TestResult.success,
                  message: 'DNS working',
                  latency: stopwatch.elapsed,
                ));
              } else {
                completer.complete(DnsttTestResult(
                  server: server,
                  result: TestResult.failed,
                  message: 'DNS error (RCODE: $rcode)',
                ));
              }
            }
          }
        }
      });

      final result = await completer.future;
      socket.close();
      return result;

    } on SocketException catch (e) {
      stopwatch.stop();
      socket?.close();
      return DnsttTestResult(
        server: server,
        result: TestResult.failed,
        message: 'Socket error: ${e.message}',
      );
    } catch (e) {
      stopwatch.stop();
      socket?.close();
      return DnsttTestResult(
        server: server,
        result: TestResult.failed,
        message: 'Error: $e',
      );
    }
  }

  /// Tests multiple DNS servers with DNSTT or Slipstream tunnel
  /// Returns true if completed, false if cancelled
  static Future<bool> testMultipleDnsServersAll(
    List<DnsServer> servers, {
    String? tunnelDomain,
    String? publicKey,
    String testUrl = 'https://api.ipify.org?format=json',
    int concurrency = 3, // Lower concurrency for real tunnel tests
    Duration timeout = const Duration(seconds: 20),
    void Function(DnsttTestResult)? onResult,
    bool Function()? shouldCancel,
    TransportType transportType = TransportType.dnstt,
    String congestionControl = 'dcubic',
    int keepAliveInterval = 400,
    bool gso = false,
  }) async {
    final queue = List<DnsServer>.from(servers);

    // For tunnel tests, use concurrency of 1 to avoid issues with multiple clients
    // and to provide immediate progress feedback
    final actualConcurrency = (tunnelDomain != null && publicKey != null)
        ? 1 // Test one at a time for real tunnel connections
        : concurrency;

    // Process servers one at a time for immediate progress updates
    if (actualConcurrency == 1) {
      for (final server in queue) {
        // Check for cancellation before each test
        if (shouldCancel?.call() == true) {
          return false;
        }

        final result = await testDnsServer(
          server,
          tunnelDomain: tunnelDomain,
          publicKey: publicKey,
          testUrl: testUrl,
          timeout: timeout,
          transportType: transportType,
          congestionControl: congestionControl,
          keepAliveInterval: keepAliveInterval,
          gso: gso,
        );

        // Call onResult immediately after each test
        onResult?.call(result);
      }
      return true;
    }

    // For non-tunnel tests (basic DNS), use batch processing
    while (queue.isNotEmpty) {
      // Check for cancellation before each batch
      if (shouldCancel?.call() == true) {
        return false;
      }

      final batch = <Future<DnsttTestResult>>[];
      final batchSize = queue.length < actualConcurrency ? queue.length : actualConcurrency;

      for (int i = 0; i < batchSize; i++) {
        final server = queue.removeAt(0);
        batch.add(testDnsServer(
          server,
          tunnelDomain: tunnelDomain,
          publicKey: publicKey,
          testUrl: testUrl,
          timeout: timeout,
          transportType: transportType,
          congestionControl: congestionControl,
          keepAliveInterval: keepAliveInterval,
          gso: gso,
        ));
      }

      // Wait for batch to complete
      final batchResults = await Future.wait(batch);
      for (final result in batchResults) {
        onResult?.call(result);
      }
    }

    return true;
  }

  /// Tests the tunnel connection by making an HTTP request through the SOCKS5 proxy
  static Future<TunnelTestResult> testTunnelConnection(
    String testUrl, {
    String proxyHost = '127.0.0.1',
    int proxyPort = 1080,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      final uri = Uri.parse(testUrl);

      // Create HTTP client with SOCKS5 proxy
      final client = HttpClient();
      client.connectionTimeout = timeout;
      client.findProxy = (uri) => 'SOCKS5 $proxyHost:$proxyPort';

      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);

      stopwatch.stop();
      client.close();

      if (response.statusCode >= 200 && response.statusCode < 400) {
        return TunnelTestResult(
          result: TestResult.success,
          message: 'HTTP ${response.statusCode}',
          latency: stopwatch.elapsed,
          statusCode: response.statusCode,
        );
      } else {
        return TunnelTestResult(
          result: TestResult.failed,
          message: 'HTTP ${response.statusCode}',
          latency: stopwatch.elapsed,
          statusCode: response.statusCode,
        );
      }
    } on TimeoutException {
      stopwatch.stop();
      return TunnelTestResult(
        result: TestResult.timeout,
        message: 'Request timed out',
        latency: stopwatch.elapsed,
      );
    } on SocketException catch (e) {
      stopwatch.stop();
      return TunnelTestResult(
        result: TestResult.failed,
        message: 'Connection failed: ${e.message}',
        latency: stopwatch.elapsed,
      );
    } on HandshakeException catch (e) {
      stopwatch.stop();
      return TunnelTestResult(
        result: TestResult.failed,
        message: 'SSL error: ${e.message}',
        latency: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return TunnelTestResult(
        result: TestResult.failed,
        message: 'Error: $e',
        latency: stopwatch.elapsed,
      );
    }
  }
}

/// Top-level function to run FFI test in a separate isolate
/// This must be a top-level function for compute() to work
int _runFfiTest(Map<String, dynamic> params) {
  final dnsServer = params['dnsServer'] as String;
  final tunnelDomain = params['tunnelDomain'] as String;
  final publicKey = params['publicKey'] as String;
  final testUrl = params['testUrl'] as String;
  final timeoutMs = params['timeoutMs'] as int;

  try {
    // Load FFI library in this isolate
    final ffi = DnsttFfiService.instance;
    if (!ffi.isLoaded) {
      ffi.load();
    }

    // Run the test
    return ffi.testDnsServer(
      dnsServer: dnsServer,
      tunnelDomain: tunnelDomain,
      publicKey: publicKey,
      testUrl: testUrl,
      timeoutMs: timeoutMs,
    );
  } catch (e) {
    print('FFI test error in isolate: $e');
    return -1;
  }
}
