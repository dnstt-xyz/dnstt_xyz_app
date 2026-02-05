import 'package:flutter/foundation.dart';
import '../models/dns_server.dart';
import '../models/dnstt_config.dart';
import '../services/storage_service.dart';
import '../services/dnstt_service.dart';
import '../services/vpn_service.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

class AppState extends ChangeNotifier {
  StorageService? _storage;
  List<DnsServer> _dnsServers = [];
  List<DnsttConfig> _dnsttConfigs = [];
  DnsttConfig? _activeConfig;
  DnsServer? _activeDns;
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  String? _connectionError;
  Map<String, bool> _testingDns = {};
  bool _isTestingAll = false;
  bool _cancelTestingRequested = false;
  int _testingProgress = 0;
  int _testingTotal = 0;
  int _testingWorking = 0;
  int _testingFailed = 0;
  String _testUrl = 'https://www.google.com';
  int _proxyPort = StorageService.defaultProxyPort;

  List<DnsServer> get dnsServers => _dnsServers;
  List<DnsttConfig> get dnsttConfigs => _dnsttConfigs;
  DnsttConfig? get activeConfig => _activeConfig;
  DnsServer? get activeDns => _activeDns;
  ConnectionStatus get connectionStatus => _connectionStatus;
  String? get connectionError => _connectionError;
  bool get isTestingAll => _isTestingAll;
  bool isDnsBeingTested(String id) => _testingDns[id] ?? false;
  String get testUrl => _testUrl;
  int get proxyPort => _proxyPort;
  int get testingProgress => _testingProgress;
  int get testingTotal => _testingTotal;
  int get testingWorking => _testingWorking;
  int get testingFailed => _testingFailed;

  List<DnsServer> get workingDnsServers =>
      _dnsServers.where((s) => s.isWorking).toList();

  Future<void> init(StorageService storage) async {
    _storage = storage;
    await _loadData();
  }

  Future<void> _loadData() async {
    _dnsServers = await _storage!.getDnsServers();
    _dnsttConfigs = await _storage!.getDnsttConfigs();

    final activeConfigId = await _storage!.getActiveConfigId();
    if (activeConfigId != null) {
      _activeConfig = _dnsttConfigs
          .where((c) => c.id == activeConfigId)
          .firstOrNull;
    }

    final activeDnsId = await _storage!.getActiveDnsId();
    if (activeDnsId != null) {
      _activeDns = _dnsServers.where((s) => s.id == activeDnsId).firstOrNull;
    }

    _testUrl = await _storage!.getTestUrl() ?? 'https://www.google.com';
    _proxyPort = await _storage!.getProxyPort();

    notifyListeners();
  }

  // DNS Server Management
  Future<void> addDnsServer(DnsServer server) async {
    await _storage!.addDnsServer(server);
    _dnsServers = await _storage!.getDnsServers();
    notifyListeners();
  }

  Future<void> addDnsServers(List<DnsServer> servers) async {
    for (final server in servers) {
      if (!_dnsServers.contains(server)) {
        _dnsServers.add(server);
      }
    }
    await _storage!.saveDnsServers(_dnsServers);
    notifyListeners();
  }

  /// Import DNS servers with deduplication based on IP address.
  /// If a server with the same IP already exists, only update its name if changed.
  /// Returns the count of new servers added and updated servers.
  Future<({int added, int updated})> importDnsServers(List<DnsServer> servers) async {
    int added = 0;
    int updated = 0;

    for (final server in servers) {
      // Find existing server by IP address
      final existingIndex = _dnsServers.indexWhere((s) => s.address == server.address);

      if (existingIndex >= 0) {
        // Server exists - check if name needs update
        final existing = _dnsServers[existingIndex];
        if (server.name != null && server.name != existing.name) {
          // Update name only
          _dnsServers[existingIndex] = DnsServer(
            id: existing.id,
            address: existing.address,
            name: server.name,
            region: server.region ?? existing.region,
            provider: server.provider ?? existing.provider,
            isWorking: existing.isWorking,
            lastTested: existing.lastTested,
            lastLatencyMs: existing.lastLatencyMs,
            lastTestMessage: existing.lastTestMessage,
          );
          updated++;
        }
      } else {
        // New server - add it
        _dnsServers.add(server);
        added++;
      }
    }

    await _storage!.saveDnsServers(_dnsServers);
    notifyListeners();

    return (added: added, updated: updated);
  }

  Future<void> removeDnsServer(String id) async {
    await _storage!.removeDnsServer(id);
    _dnsServers = await _storage!.getDnsServers();
    if (_activeDns?.id == id) {
      _activeDns = null;
      await _storage!.setActiveDnsId(null);
    }
    notifyListeners();
  }

  Future<void> clearAllDnsServers() async {
    _dnsServers.clear();
    await _storage!.saveDnsServers(_dnsServers);
    _activeDns = null;
    await _storage!.setActiveDnsId(null);
    notifyListeners();
  }

  Future<void> updateDnsServerStatus(String id, bool isWorking, {int? latencyMs, String? message}) async {
    final server = _dnsServers.firstWhere((s) => s.id == id);
    server.isWorking = isWorking;
    server.lastTested = DateTime.now();
    server.lastLatencyMs = latencyMs;
    server.lastTestMessage = message;
    await _storage!.updateDnsServer(server);
    notifyListeners();
  }

  // DNSTT Config Management
  Future<void> addDnsttConfig(DnsttConfig config) async {
    await _storage!.addDnsttConfig(config);
    _dnsttConfigs = await _storage!.getDnsttConfigs();
    notifyListeners();
  }

  /// Import multiple DNSTT configs with deduplication based on tunnelDomain + publicKey.
  /// Returns the count of new configs added and updated configs.
  Future<({int added, int updated})> importDnsttConfigs(List<DnsttConfig> configs) async {
    int added = 0;
    int updated = 0;

    for (final config in configs) {
      // Find existing config by domain and public key
      final existingIndex = _dnsttConfigs.indexWhere(
        (c) => c.tunnelDomain == config.tunnelDomain && c.publicKey == config.publicKey,
      );

      if (existingIndex >= 0) {
        // Config exists - update name if different
        final existing = _dnsttConfigs[existingIndex];
        if (config.name != existing.name) {
          existing.name = config.name;
          await _storage!.updateDnsttConfig(existing);
          updated++;
        }
      } else {
        // New config - add it
        await _storage!.addDnsttConfig(config);
        added++;
      }
    }

    _dnsttConfigs = await _storage!.getDnsttConfigs();
    notifyListeners();

    return (added: added, updated: updated);
  }

  Future<void> updateDnsttConfig(DnsttConfig config) async {
    await _storage!.updateDnsttConfig(config);
    _dnsttConfigs = await _storage!.getDnsttConfigs();
    if (_activeConfig?.id == config.id) {
      _activeConfig = config;
    }
    notifyListeners();
  }

  Future<void> removeDnsttConfig(String id) async {
    await _storage!.removeDnsttConfig(id);
    _dnsttConfigs = await _storage!.getDnsttConfigs();
    if (_activeConfig?.id == id) {
      _activeConfig = null;
      await _storage!.setActiveConfigId(null);
    }
    notifyListeners();
  }

  // Active selections
  Future<void> setActiveConfig(DnsttConfig? config) async {
    _activeConfig = config;
    await _storage!.setActiveConfigId(config?.id);
    notifyListeners();
  }

  Future<void> setActiveDns(DnsServer? dns) async {
    _activeDns = dns;
    await _storage!.setActiveDnsId(dns?.id);
    notifyListeners();
  }

  // Testing
  void setDnsTesting(String id, bool testing) {
    _testingDns[id] = testing;
    notifyListeners();
  }

  void setTestingAll(bool testing) {
    _isTestingAll = testing;
    notifyListeners();
  }

  /// Start testing all DNS servers in the background
  /// This continues even when the user leaves the DNS management screen
  Future<void> startTestingAllDnsServers() async {
    if (_isTestingAll) return; // Already testing
    if (_dnsServers.isEmpty) return;

    _isTestingAll = true;
    _cancelTestingRequested = false;
    _testingProgress = 0;
    _testingTotal = _dnsServers.length;
    _testingWorking = 0;
    _testingFailed = 0;
    notifyListeners();

    // Reset native cancellation state before starting
    final vpnService = VpnService();
    await vpnService.init();
    await vpnService.resetTestCancellation();

    final servers = List<DnsServer>.from(_dnsServers);
    final tunnelDomain = _activeConfig?.tunnelDomain;
    final publicKey = _activeConfig?.publicKey;

    try {
      // Check if testing is supported
      if (!isTestingSupported) {
        // Mark all as failed with unsupported message
        for (final server in servers) {
          _testingProgress++;
          _testingFailed++;
          await updateDnsServerStatus(
            server.id,
            false,
            message: testingUnsupportedMessage,
          );
        }
      } else {
        // Use the batch testing method (works for both DNSTT and Slipstream)
        final transportType = _activeConfig?.transportType ?? TransportType.dnstt;
        await DnsttService.testMultipleDnsServersAll(
          servers,
          tunnelDomain: tunnelDomain,
          publicKey: publicKey,
          testUrl: _testUrl,
          concurrency: 3,
          timeout: const Duration(seconds: 15),
          shouldCancel: () => _cancelTestingRequested,
          transportType: transportType,
          congestionControl: _activeConfig?.congestionControl ?? 'dcubic',
          keepAliveInterval: _activeConfig?.keepAliveInterval ?? 400,
          gso: _activeConfig?.gsoEnabled ?? false,
          onResult: (result) async {
            if (result.message == 'Cancelled') {
              _testingProgress++;
              notifyListeners();
              return;
            }

            _testingProgress++;

            if (result.result == TestResult.success) {
              _testingWorking++;
            } else {
              _testingFailed++;
            }

            await updateDnsServerStatus(
              result.server.id,
              result.result == TestResult.success,
              latencyMs: result.latency?.inMilliseconds,
              message: result.message,
            );
          },
        );
      }
    } finally {
      _isTestingAll = false;
      _cancelTestingRequested = false;

      // Sort servers by latency after testing (working first, then by latency)
      _sortServersByLatency();

      notifyListeners();
    }
  }

  /// Sort DNS servers: working (by latency) → not tested → failed
  void _sortServersByLatency() {
    _dnsServers.sort((a, b) {
      // Priority: working (0) > not tested (1) > failed (2)
      int priorityA = _getServerPriority(a);
      int priorityB = _getServerPriority(b);

      if (priorityA != priorityB) {
        return priorityA.compareTo(priorityB);
      }

      // Among working servers, sort by latency (lower is better)
      if (priorityA == 0) {
        final latencyA = a.lastLatencyMs ?? 999999;
        final latencyB = b.lastLatencyMs ?? 999999;
        return latencyA.compareTo(latencyB);
      }

      // Keep original order for not tested and failed servers
      return 0;
    });

    // Save sorted order to storage
    _storage?.saveDnsServers(_dnsServers);
  }

  /// Get priority for sorting: 0 = working, 1 = not tested, 2 = failed
  int _getServerPriority(DnsServer server) {
    if (server.lastTested == null) {
      return 1; // Not tested
    } else if (server.isWorking) {
      return 0; // Working
    } else {
      return 2; // Failed
    }
  }

  /// Check if testing is supported for the current config
  bool get isTestingSupported {
    if (_activeConfig == null) return true; // No config, basic DNS test
    // SSH tunnel testing not supported yet
    if (_activeConfig!.tunnelType == TunnelType.ssh) return false;
    // Slipstream testing is supported on all platforms
    return true;
  }

  /// Get message for unsupported testing
  String get testingUnsupportedMessage {
    if (_activeConfig?.tunnelType == TunnelType.ssh) {
      return 'Testing not available for SSH tunnel configs yet';
    }
    return '';
  }

  /// Test a single DNS server
  Future<void> testSingleDnsServer(DnsServer server) async {
    if (_testingDns[server.id] == true) return; // Already testing this server

    // Check if testing is supported for current config
    if (!isTestingSupported) {
      await updateDnsServerStatus(
        server.id,
        false,
        message: testingUnsupportedMessage,
      );
      return;
    }

    _testingDns[server.id] = true;
    notifyListeners();

    try {
      final tunnelDomain = _activeConfig?.tunnelDomain;
      final publicKey = _activeConfig?.publicKey;

      // Full tunnel test (works for both DNSTT and Slipstream)
      final transportType = _activeConfig?.transportType ?? TransportType.dnstt;
      final result = await DnsttService.testDnsServer(
        server,
        tunnelDomain: tunnelDomain,
        publicKey: publicKey,
        testUrl: _testUrl,
        timeout: const Duration(seconds: 15),
        transportType: transportType,
        congestionControl: _activeConfig?.congestionControl ?? 'dcubic',
        keepAliveInterval: _activeConfig?.keepAliveInterval ?? 400,
        gso: _activeConfig?.gsoEnabled ?? false,
      );

      await updateDnsServerStatus(
        server.id,
        result.result == TestResult.success,
        latencyMs: result.latency?.inMilliseconds,
        message: result.message,
      );
    } finally {
      _testingDns[server.id] = false;
      notifyListeners();
    }
  }

  /// Cancel the ongoing test
  Future<void> cancelTesting() async {
    if (_isTestingAll) {
      _cancelTestingRequested = true;
      notifyListeners();

      // Also cancel native tests (Android)
      final vpnService = VpnService();
      await vpnService.init();
      await vpnService.cancelAllTests();
    }
  }

  // Connection
  void setConnectionStatus(ConnectionStatus status, [String? error]) {
    _connectionStatus = status;
    _connectionError = error;
    notifyListeners();
  }

  // Test URL
  Future<void> setTestUrl(String url) async {
    _testUrl = url;
    await _storage!.setTestUrl(url);
    notifyListeners();
  }

  // Proxy Port
  Future<void> setProxyPort(int port) async {
    _proxyPort = port;
    await _storage!.setProxyPort(port);
    notifyListeners();
  }
}
