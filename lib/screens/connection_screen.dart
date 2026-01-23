import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/vpn_service.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final VpnService _vpnService = VpnService();
  StreamSubscription<VpnState>? _vpnStateSubscription;
  VpnState _vpnState = VpnState.disconnected;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initVpn();
  }

  Future<void> _initVpn() async {
    await _vpnService.init();
    _vpnStateSubscription = _vpnService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _vpnState = state;
        });
        _syncWithAppState(state);
      }
    });
    setState(() {
      _vpnState = _vpnService.currentState;
    });
  }

  void _syncWithAppState(VpnState vpnState) {
    final appState = context.read<AppState>();
    switch (vpnState) {
      case VpnState.disconnected:
        appState.setConnectionStatus(ConnectionStatus.disconnected);
        break;
      case VpnState.connecting:
        appState.setConnectionStatus(ConnectionStatus.connecting);
        break;
      case VpnState.connected:
        appState.setConnectionStatus(ConnectionStatus.connected);
        break;
      case VpnState.disconnecting:
        appState.setConnectionStatus(ConnectionStatus.connecting);
        break;
      case VpnState.error:
        appState.setConnectionStatus(ConnectionStatus.error, _errorMessage);
        break;
    }
  }

  @override
  void dispose() {
    _vpnStateSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VPN Connection'),
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildConnectionStatus(context, state),
                const SizedBox(height: 24),
                _buildConfigInfo(context, state),
                const SizedBox(height: 24),
                _buildConnectionControls(context, state),
                const SizedBox(height: 24),
                _buildTrafficInfo(context, state),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildConnectionStatus(BuildContext context, AppState state) {
    final statusColor = switch (_vpnState) {
      VpnState.connected => Colors.green,
      VpnState.connecting || VpnState.disconnecting => Colors.orange,
      VpnState.error => Colors.red,
      VpnState.disconnected => Colors.grey,
    };

    final statusText = switch (_vpnState) {
      VpnState.connected => 'VPN Connected',
      VpnState.connecting => 'Connecting...',
      VpnState.disconnecting => 'Disconnecting...',
      VpnState.error => 'Connection Error',
      VpnState.disconnected => 'Disconnected',
    };

    final statusIcon = switch (_vpnState) {
      VpnState.connected => Icons.shield,
      VpnState.connecting || VpnState.disconnecting => Icons.sync,
      VpnState.error => Icons.error_outline,
      VpnState.disconnected => Icons.shield_outlined,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(color: statusColor, width: 3),
              ),
              child: _vpnState == VpnState.connecting ||
                      _vpnState == VpnState.disconnecting
                  ? Padding(
                      padding: const EdgeInsets.all(30),
                      child: CircularProgressIndicator(
                        color: statusColor,
                        strokeWidth: 4,
                      ),
                    )
                  : Icon(statusIcon, size: 56, color: statusColor),
            ),
            const SizedBox(height: 16),
            Text(
              statusText,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
            ),
            if (_errorMessage != null && _vpnState == VpnState.error) ...[
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ],
            if (_vpnState == VpnState.connected) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock, color: Colors.green, size: 16),
                    SizedBox(width: 8),
                    Text(
                      'All traffic is tunneled',
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConfigInfo(BuildContext context, AppState state) {
    if (state.activeConfig == null || state.activeDns == null) {
      return Card(
        color: Colors.orange.shade50,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.warning, color: Colors.orange),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Please select a DNSTT config and DNS server before connecting',
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.settings, size: 20),
                SizedBox(width: 8),
                Text(
                  'Tunnel Configuration',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const Divider(),
            _buildInfoTile('Config', state.activeConfig!.name),
            _buildInfoTile('Domain', state.activeConfig!.tunnelDomain),
            _buildInfoTile('DNS Server', state.activeDns!.address),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionControls(BuildContext context, AppState state) {
    final canConnect = state.activeConfig != null && state.activeDns != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_vpnState == VpnState.disconnected || _vpnState == VpnState.error)
          ElevatedButton.icon(
            onPressed: canConnect ? () => _connect(state) : null,
            icon: const Icon(Icons.power_settings_new, size: 28),
            label: const Text('Connect VPN', style: TextStyle(fontSize: 18)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 20),
            ),
          )
        else if (_vpnState == VpnState.connecting ||
            _vpnState == VpnState.disconnecting)
          ElevatedButton.icon(
            onPressed: null,
            icon: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            label: Text(
              _vpnState == VpnState.connecting
                  ? 'Connecting...'
                  : 'Disconnecting...',
              style: const TextStyle(fontSize: 18),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 20),
            ),
          )
        else
          ElevatedButton.icon(
            onPressed: _disconnect,
            icon: const Icon(Icons.stop, size: 28),
            label:
                const Text('Disconnect VPN', style: TextStyle(fontSize: 18)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 20),
            ),
          ),
      ],
    );
  }

  Widget _buildTrafficInfo(BuildContext context, AppState state) {
    return Card(
      color: _vpnState == VpnState.connected
          ? Colors.green.shade50
          : Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _vpnState == VpnState.connected
                      ? Icons.check_circle
                      : Icons.info_outline,
                  color:
                      _vpnState == VpnState.connected ? Colors.green : Colors.blue,
                ),
                const SizedBox(width: 8),
                Text(
                  _vpnState == VpnState.connected
                      ? 'VPN Active'
                      : 'How it works',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _vpnState == VpnState.connected
                  ? 'All device traffic is being routed through the DNSTT tunnel. Your connection is encrypted and tunneled via DNS queries.'
                  : 'When connected, the VPN will route all device traffic through the DNSTT tunnel using DNS queries to bypass network restrictions.',
              style: TextStyle(
                color: _vpnState == VpnState.connected
                    ? Colors.green.shade800
                    : Colors.blue.shade800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _connect(AppState state) async {
    setState(() {
      _errorMessage = null;
    });

    // Request VPN permission first
    final hasPermission = await _vpnService.requestPermission();
    if (!hasPermission) {
      setState(() {
        _errorMessage = 'VPN permission denied';
        _vpnState = VpnState.error;
      });
      return;
    }

    // Connect to VPN
    final success = await _vpnService.connect(
      proxyHost: '127.0.0.1',
      proxyPort: 1080,
      dnsServer: state.activeDns!.address,
      tunnelDomain: state.activeConfig!.tunnelDomain,
      publicKey: state.activeConfig!.publicKey,
    );

    if (!success && mounted) {
      setState(() {
        _errorMessage = 'VPN requires paid Apple Developer account.\nNetwork Extension entitlement is not available with free accounts.';
      });
    }
  }

  Future<void> _disconnect() async {
    await _vpnService.disconnect();
  }
}
