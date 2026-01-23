import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/dns_server.dart';
import '../services/dnstt_service.dart';
import '../services/vpn_service.dart';
import 'dart:developer' as developer;

class TestScreen extends StatefulWidget {
  const TestScreen({super.key});

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  final TextEditingController _testUrlController = TextEditingController();
  final VpnService _vpnService = VpnService();

  bool _isTesting = false;
  int _testedCount = 0;
  int _totalCount = 0;
  String? _currentlyTesting;

  @override
  void initState() {
    super.initState();
    _vpnService.init();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = Provider.of<AppState>(context, listen: false);
      _testUrlController.text = state.testUrl;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test DNS Servers'),
        actions: [
          if (_isTesting)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            ),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          final config = state.activeConfig;

          if (config == null) {
            return const Center(
              child: Text('Please select a DNSTT config first'),
            );
          }

          if (state.dnsServers.isEmpty) {
            return const Center(
              child: Text('No DNS servers to test. Import some first.'),
            );
          }

          return Column(
            children: [
              // Test Configuration Section
              Container(
                padding: const EdgeInsets.all(16),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Config: ${config.name}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                config.tunnelDomain,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _testUrlController,
                      decoration: const InputDecoration(
                        labelText: 'Test URL',
                        hintText: 'https://www.google.com',
                        isDense: true,
                      ),
                      onChanged: (value) => state.setTestUrl(value),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isTesting ? null : () => _testAll(state),
                        icon: const Icon(Icons.play_arrow),
                        label: Text(_isTesting ? 'Testing...' : 'Test All DNS Servers'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    if (_isTesting) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: _totalCount > 0 ? _testedCount / _totalCount : 0,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Testing $_testedCount / $_totalCount${_currentlyTesting != null ? ' - $_currentlyTesting' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              // DNS Servers List
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: state.dnsServers.length,
                  itemBuilder: (context, index) {
                    final server = state.dnsServers[index];
                    final isActive = state.activeDns?.id == server.id;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: isActive
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                      child: ListTile(
                        leading: _buildStatusIcon(server),
                        title: Text(
                          server.address,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (server.region != null || server.provider != null)
                              Text(
                                [
                                  if (server.region != null) server.region,
                                  if (server.provider != null) server.provider,
                                ].join(' - '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            if (server.lastTestMessage != null)
                              Text(
                                _getResultText(server),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: server.isWorking
                                      ? Colors.green
                                      : Colors.red,
                                ),
                              ),
                          ],
                        ),
                        trailing: server.isWorking
                            ? IconButton(
                                icon: Icon(
                                  isActive ? Icons.check_circle : Icons.add_circle_outline,
                                  color: isActive ? Colors.green : null,
                                ),
                                onPressed: () => state.setActiveDns(server),
                                tooltip: isActive ? 'Selected' : 'Use this DNS',
                              )
                            : null,
                      ),
                    );
                  },
                ),
              ),
              // Summary Footer
              if (state.dnsServers.any((s) => s.lastTested != null))
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStat(
                        'Total',
                        state.dnsServers.length.toString(),
                        Colors.blue,
                      ),
                      _buildStat(
                        'Working',
                        state.workingDnsServers.length.toString(),
                        Colors.green,
                      ),
                      _buildStat(
                        'Failed',
                        state.dnsServers
                            .where((s) => s.lastTested != null && !s.isWorking)
                            .length
                            .toString(),
                        Colors.red,
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusIcon(DnsServer server) {
    if (server.lastTested == null) {
      return const CircleAvatar(
        backgroundColor: Colors.grey,
        child: Icon(Icons.help_outline, color: Colors.white, size: 20),
      );
    }

    if (server.isWorking) {
      return const CircleAvatar(
        backgroundColor: Colors.green,
        child: Icon(Icons.check, color: Colors.white, size: 20),
      );
    } else {
      return const CircleAvatar(
        backgroundColor: Colors.red,
        child: Icon(Icons.close, color: Colors.white, size: 20),
      );
    }
  }

  String _getResultText(DnsServer server) {
    if (server.isWorking) {
      final latency = server.lastLatencyMs;
      final message = server.lastTestMessage ?? 'Success';
      return latency != null ? '$message (${latency}ms)' : message;
    } else {
      return server.lastTestMessage ?? 'Failed';
    }
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Future<void> _testAll(AppState state) async {
    developer.log('Test All button clicked');

    final testUrl = _testUrlController.text.trim();
    if (testUrl.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a test URL')),
      );
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Starting test for ${state.dnsServers.length} DNS servers...')),
    );

    // Request VPN permission first
    developer.log('Requesting VPN permission');
    final permissionGranted = await _vpnService.requestPermission();
    if (!permissionGranted) {
      if (!mounted) return;
      developer.log('VPN permission denied');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('VPN permission denied'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    developer.log('VPN permission granted, starting tests');

    setState(() {
      _isTesting = true;
      _testedCount = 0;
      _totalCount = state.dnsServers.length;
      _currentlyTesting = null;
    });

    for (final server in state.dnsServers) {
      if (!_isTesting || !mounted) break;

      try {
        setState(() {
          _currentlyTesting = server.address;
        });

        developer.log('Testing DNS: ${server.address}');

        // Start VPN with this DNS server with timeout
        developer.log('Connecting VPN with DNS: ${server.address}');

        bool connected = false;
        try {
          connected = await _vpnService.connect(
            proxyHost: '127.0.0.1',
            proxyPort: 1080,
            dnsServer: server.address,
            tunnelDomain: state.activeConfig?.tunnelDomain,
            publicKey: state.activeConfig?.publicKey,
          ).timeout(const Duration(seconds: 10));
        } catch (e) {
          developer.log('VPN connection timeout/error for ${server.address}: $e');
          connected = false;
        }

        if (!connected) {
          // Failed to connect VPN
          developer.log('VPN connection failed for ${server.address}');
          await state.updateDnsServerStatus(
            server.id,
            false,
            message: 'VPN connection failed',
          );
          setState(() {
            _testedCount++;
          });
          continue;
        }

        developer.log('VPN connected, waiting 3s for stabilization');
        // Wait for the tunnel to stabilize
        await Future.delayed(const Duration(seconds: 3));

        // Test the tunnel connection with timeout
        developer.log('Testing tunnel connection to $testUrl');
        final result = await DnsttService.testTunnelConnection(
          testUrl,
          timeout: const Duration(seconds: 15),
        );

        developer.log('Test result: ${result.result}, message: ${result.message}');

        // Disconnect VPN and wait for cleanup
        developer.log('Disconnecting VPN');
        try {
          await _vpnService.disconnect().timeout(const Duration(seconds: 5));
        } catch (e) {
          developer.log('Disconnect timeout: $e');
        }
        await Future.delayed(const Duration(seconds: 1));

        if (!mounted) break;

        // Update DNS server status
        await state.updateDnsServerStatus(
          server.id,
          result.result == TestResult.success,
          latencyMs: result.latency?.inMilliseconds,
          message: result.message,
        );

        setState(() {
          _testedCount++;
        });
      } catch (e) {
        developer.log('Error testing ${server.address}: $e');
        await state.updateDnsServerStatus(
          server.id,
          false,
          message: 'Error: $e',
        );
        setState(() {
          _testedCount++;
        });

        // Make sure to disconnect on error
        try {
          await _vpnService.disconnect().timeout(const Duration(seconds: 5));
        } catch (_) {}
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    if (mounted) {
      setState(() {
        _isTesting = false;
        _currentlyTesting = null;
      });

      final workingCount = state.workingDnsServers.length;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Testing complete: $workingCount working DNS servers'),
        ),
      );
    }
  }

  @override
  void dispose() {
    _isTesting = false;
    _testUrlController.dispose();
    super.dispose();
  }
}
