import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/app_state.dart';
import '../services/vpn_service.dart';
import '../models/dnstt_config.dart';
import 'dns_management_screen.dart';
import 'config_management_screen.dart';
import 'donate_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum ConnectionMode { vpn, proxy }

class _HomeScreenState extends State<HomeScreen> {
  final VpnService _vpnService = VpnService();
  ConnectionMode _connectionMode = ConnectionMode.vpn;

  @override
  void initState() {
    super.initState();
    _vpnService.init();

    // Restore saved connection mode
    final appState = Provider.of<AppState>(context, listen: false);
    _connectionMode = appState.connectionMode == 'proxy'
        ? ConnectionMode.proxy
        : ConnectionMode.vpn;

    // Listen to VPN state changes and update app state accordingly
    _vpnService.stateStream.listen((vpnState) {
      final appState = Provider.of<AppState>(context, listen: false);
      switch (vpnState) {
        case VpnState.connecting:
          appState.setConnectionStatus(ConnectionStatus.connecting);
          break;
        case VpnState.connected:
          appState.setConnectionStatus(ConnectionStatus.connected);
          break;
        case VpnState.disconnected:
        case VpnState.disconnecting:
          appState.setConnectionStatus(ConnectionStatus.disconnected);
          break;
        case VpnState.error:
          appState.setConnectionStatus(ConnectionStatus.error, 'VPN connection failed');
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DNSTT.XYZ'),
        centerTitle: true,
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildVpnConnectionCard(context, state),
                const SizedBox(height: 16),
                _buildMenuCards(context, state),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildProxyNotice(BuildContext context, AppState state) {
    final isSshTunnel = _vpnService.isSshTunnelMode;
    final proxyAddress = _vpnService.socksProxyAddress;
    final proxyPort = state.proxyPort;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, size: 20, color: Colors.green),
              const SizedBox(width: 8),
              Text(
                isSshTunnel ? 'SSH Tunnel Active' : 'SOCKS5 Proxy Active',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.green,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Local Proxy Address:',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: SelectableText(
                    proxyAddress,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: Colors.green,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    Clipboard.setData(ClipboardData(
                      text: proxyAddress,
                    ));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Address copied!'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.copy, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                final telegramUrl = Uri.parse(
                  'tg://socks?server=127.0.0.1&port=$proxyPort'
                );
                if (await canLaunchUrl(telegramUrl)) {
                  await launchUrl(telegramUrl);
                } else {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Telegram is not installed or cannot open the link'),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.send, size: 18),
              label: const Text('Add Proxy to Telegram'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0088CC),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVpnConnectionCard(BuildContext context, AppState state) {
    final isConnected = state.connectionStatus == ConnectionStatus.connected;
    final isConnecting = state.connectionStatus == ConnectionStatus.connecting;
    final isDisconnected = state.connectionStatus == ConnectionStatus.disconnected;
    final isError = state.connectionStatus == ConnectionStatus.error;
    final canConnect = state.activeConfig != null && state.activeDns != null;

    final statusColor = switch (state.connectionStatus) {
      ConnectionStatus.connected => Colors.green,
      ConnectionStatus.connecting => Colors.orange,
      ConnectionStatus.error => Colors.red,
      ConnectionStatus.disconnected => Colors.grey,
    };

    final statusText = switch (state.connectionStatus) {
      ConnectionStatus.connected => 'Connected',
      ConnectionStatus.connecting => 'Connecting...',
      ConnectionStatus.error => 'Error',
      ConnectionStatus.disconnected => 'Disconnected',
    };

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Large toggle button
            GestureDetector(
              onTap: () {
                if (isConnecting) {
                  _cancelConnection(context, state);
                } else if (isConnected) {
                  _disconnect(context, state);
                } else if (canConnect && (isDisconnected || isError)) {
                  _connect(context, state);
                }
              },
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isConnected
                      ? Colors.green
                      : isConnecting
                          ? Colors.orange
                          : isError
                              ? Colors.red[700]
                              : (canConnect ? Colors.grey[700] : Colors.grey[400]),
                  boxShadow: [
                    BoxShadow(
                      color: (isConnected ? Colors.green : isConnecting ? Colors.orange : Colors.grey).withOpacity(0.3),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Center(
                  child: isConnecting
                      ? const Icon(
                          Icons.close,
                          size: 60,
                          color: Colors.white,
                        )
                      : Icon(
                          isError ? Icons.refresh : Icons.power_settings_new,
                          size: 60,
                          color: isConnected || canConnect || isError
                              ? Colors.white
                              : Colors.grey[300],
                        ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Status text
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),

            if (isConnecting) ...[
              const SizedBox(height: 4),
              Text(
                'Tap to cancel',
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],

            if (state.connectionError != null) ...[
              const SizedBox(height: 8),
              Text(
                state.connectionError!,
                style: TextStyle(color: Colors.red[300], fontSize: 12),
                textAlign: TextAlign.center,
              ),
              if (isError && canConnect) ...[
                const SizedBox(height: 4),
                Text(
                  'Tap to retry',
                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ],
            ],

            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),

            // Config info
            if (state.activeConfig != null) ...[
              _buildInfoItem(
                context,
                Icons.settings,
                'Config',
                state.activeConfig!.name,
              ),
              const SizedBox(height: 8),
              _buildInfoItem(
                context,
                Icons.language,
                'Domain',
                state.activeConfig!.tunnelDomain,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    state.activeConfig!.tunnelType == TunnelType.ssh
                        ? Icons.terminal
                        : Icons.lan,
                    size: 20,
                    color: Colors.grey[600],
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Type: ',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: state.activeConfig!.tunnelType == TunnelType.ssh
                          ? Colors.purple[100]
                          : Colors.blue[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      state.activeConfig!.tunnelType == TunnelType.ssh ? 'SSH' : 'Socks',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: state.activeConfig!.tunnelType == TunnelType.ssh
                            ? Colors.purple[700]
                            : Colors.blue[700],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: state.activeConfig!.isSlipstream
                          ? Colors.orange[100]
                          : Colors.teal[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      state.activeConfig!.isSlipstream ? 'Slipstream' : 'DNSTT',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: state.activeConfig!.isSlipstream
                            ? Colors.orange[700]
                            : Colors.teal[700],
                      ),
                    ),
                  ),
                ],
              ),
            ] else
              _buildInfoItem(
                context,
                Icons.settings,
                'Config',
                'No config selected',
                isPlaceholder: true,
              ),

            const SizedBox(height: 8),

            // DNS info
            if (state.activeDns != null)
              _buildInfoItem(
                context,
                Icons.dns,
                'DNS',
                state.activeDns!.address,
              )
            else
              _buildInfoItem(
                context,
                Icons.dns,
                'DNS',
                'No DNS selected',
                isPlaceholder: true,
              ),

            if (!canConnect && isDisconnected) ...[
              const SizedBox(height: 16),
              Text(
                'Select a config and DNS server to connect',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ],

            // Mode toggle for Android (VPN or Proxy)
            if (Platform.isAndroid && isDisconnected && canConnect) ...[
              const SizedBox(height: 16),
              _buildModeToggle(context),
            ],

            // Show proxy notice when connected in proxy mode (desktop or Android proxy mode)
            if (isConnected && (VpnService.isDesktopPlatform || _vpnService.isProxyMode || (_vpnService.isSshTunnelMode && _connectionMode == ConnectionMode.proxy))) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),
              _buildProxyNotice(context, state),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModeToggle(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeButton(
            context,
            icon: Icons.vpn_key,
            label: 'VPN Mode',
            isSelected: _connectionMode == ConnectionMode.vpn,
            onTap: () {
              setState(() => _connectionMode = ConnectionMode.vpn);
              Provider.of<AppState>(context, listen: false).setConnectionMode('vpn');
            },
          ),
          const SizedBox(width: 4),
          _buildModeButton(
            context,
            icon: Icons.lan,
            label: 'Proxy Mode',
            isSelected: _connectionMode == ConnectionMode.proxy,
            onTap: () {
              setState(() => _connectionMode = ConnectionMode.proxy);
              Provider.of<AppState>(context, listen: false).setConnectionMode('proxy');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildModeButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected ? Colors.blue : Colors.grey[600],
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.blue : Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoItem(
    BuildContext context,
    IconData icon,
    String label,
    String value, {
    bool isPlaceholder = false,
  }) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey[600]),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(
            color: Colors.grey[600],
            fontSize: 14,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontWeight: isPlaceholder ? FontWeight.normal : FontWeight.w500,
              fontSize: 14,
              color: isPlaceholder ? Colors.grey[400] : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildMenuCards(BuildContext context, AppState state) {
    return Column(
      children: [
        _buildMenuCard(
          context,
          icon: Icons.settings,
          title: 'DNSTT Configs',
          subtitle: '${state.dnsttConfigs.length} configurations',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ConfigManagementScreen()),
          ),
        ),
        const SizedBox(height: 12),
        _buildMenuCard(
          context,
          icon: Icons.dns,
          title: 'DNS Servers',
          subtitle: '${state.dnsServers.length} servers',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DnsManagementScreen()),
          ),
        ),
        const SizedBox(height: 12),
        _buildMenuCard(
          context,
          icon: Icons.settings,
          title: 'Settings',
          subtitle: 'Proxy port: ${state.proxyPort}',
          onTap: () => _showSettingsDialog(context, state),
          color: Colors.blueGrey,
        ),
        const SizedBox(height: 12),
        _buildMenuCard(
          context,
          icon: Icons.favorite,
          title: 'Support Us',
          subtitle: 'Donate to help improve the app',
          onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DonateScreen()),
              ),
          color: Colors.red,
        ),
        const SizedBox(height: 12),
        _buildMenuCard(
          context,
          icon: Icons.language,
          title: 'Website',
          subtitle: 'Visit dnstt.xyz',
          onTap: () async {
            final url = Uri.parse('https://dnstt.xyz');
            if (await canLaunchUrl(url)) {
              await launchUrl(url, mode: LaunchMode.externalApplication);
            }
          },
          color: Colors.blue,
        ),
      ],
    );
  }

  Widget _buildMenuCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Color? color,
  }) {
    return Card(
      child: ListTile(
        leading: Icon(icon, size: 32, color: color),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
        enabled: onTap != null,
      ),
    );
  }

  void _showSettingsDialog(BuildContext context, AppState state) {
    final TextEditingController portController = TextEditingController(
      text: state.proxyPort.toString(),
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Local Proxy Port',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                hintText: '1080',
                helperText: 'Port for local SOCKS5 proxy (1-65535)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Note: Change takes effect on next connection.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final portText = portController.text.trim();
              final port = int.tryParse(portText);
              if (port != null && port >= 1 && port <= 65535) {
                state.setProxyPort(port);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Proxy port set to $port'),
                    backgroundColor: Colors.green,
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter a valid port (1-65535)'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _connect(BuildContext context, AppState state) async {
    final isDesktop = VpnService.isDesktopPlatform;
    final isSshTunnel = state.activeConfig?.tunnelType == TunnelType.ssh;
    final isSlipstream = state.activeConfig?.isSlipstream ?? false;
    final useProxyMode = isDesktop || (Platform.isAndroid && _connectionMode == ConnectionMode.proxy);

    // Determine connection type for permission and messages
    String connectionType;
    final protocolName = isSlipstream ? 'Slipstream' : 'DNSTT';
    if (isSshTunnel) {
      connectionType = useProxyMode ? 'SSH tunnel (proxy)' : 'SSH tunnel (VPN)';
    } else {
      connectionType = useProxyMode ? '$protocolName proxy' : '$protocolName VPN';
    }

    // Validate SSH settings if SSH tunnel type
    if (isSshTunnel) {
      final config = state.activeConfig!;
      if (config.sshUsername == null || config.sshUsername!.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('SSH username is required. Please configure in settings.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      if ((config.sshPassword == null || config.sshPassword!.isEmpty) &&
          (config.sshPrivateKey == null || config.sshPrivateKey!.isEmpty)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('SSH password or private key is required.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    // Request VPN permission first (no-op on desktop and proxy mode)
    final needsVpnPermission = !isDesktop && !useProxyMode;
    if (needsVpnPermission) {
      final permissionGranted = await _vpnService.requestPermission();
      if (!permissionGranted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$connectionType permission denied'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    // Set the proxy port on VpnService for display purposes
    _vpnService.proxyPort = state.proxyPort;

    bool success;

    if (isSshTunnel && useProxyMode) {
      // SSH tunnel in proxy mode - DNSTT + SSH, no VPN
      final config = state.activeConfig!;
      success = await _vpnService.connectSshTunnel(
        dnsServer: state.activeDns?.address ?? '8.8.8.8',
        tunnelDomain: config.tunnelDomain,
        publicKey: config.publicKey,
        sshUsername: config.sshUsername!,
        sshPassword: config.sshPassword,
        sshPrivateKey: config.sshPrivateKey,
      );
    } else if (isSshTunnel && !useProxyMode) {
      // SSH tunnel in VPN mode - DNSTT + SSH + VPN routing
      final config = state.activeConfig!;
      success = await _vpnService.connectSshTunnelVpn(
        dnsServer: state.activeDns?.address ?? '8.8.8.8',
        tunnelDomain: config.tunnelDomain,
        publicKey: config.publicKey,
        sshUsername: config.sshUsername!,
        sshPassword: config.sshPassword,
        sshPrivateKey: config.sshPrivateKey,
      );
    } else if (isSlipstream && useProxyMode) {
      // Slipstream in proxy mode
      final config = state.activeConfig!;
      success = await _vpnService.connectSlipstreamProxy(
        dnsServer: state.activeDns?.address ?? '8.8.8.8',
        tunnelDomain: config.tunnelDomain,
        proxyPort: state.proxyPort,
        congestionControl: config.congestionControl ?? 'dcubic',
        keepAliveInterval: config.keepAliveInterval ?? 400,
        gso: config.gsoEnabled ?? false,
      );
    } else if (isSlipstream && !useProxyMode) {
      // Slipstream in VPN mode (Android)
      final config = state.activeConfig!;
      success = await _vpnService.connectSlipstream(
        dnsServer: state.activeDns?.address ?? '8.8.8.8',
        tunnelDomain: config.tunnelDomain,
        congestionControl: config.congestionControl ?? 'dcubic',
        keepAliveInterval: config.keepAliveInterval ?? 400,
        gso: config.gsoEnabled ?? false,
      );
    } else if (useProxyMode) {
      // Proxy-only mode (desktop or Android proxy mode)
      success = await _vpnService.connectProxy(
        dnsServer: state.activeDns?.address ?? '8.8.8.8',
        tunnelDomain: state.activeConfig?.tunnelDomain,
        publicKey: state.activeConfig?.publicKey,
        proxyPort: state.proxyPort,
      );
    } else {
      // VPN mode (Android)
      success = await _vpnService.connect(
        proxyHost: '127.0.0.1',
        proxyPort: state.proxyPort,
        dnsServer: state.activeDns?.address ?? '8.8.8.8',
        tunnelDomain: state.activeConfig?.tunnelDomain,
        publicKey: state.activeConfig?.publicKey,
      );
    }

    if (context.mounted) {
      if (success) {
        String successMessage;
        if (isSshTunnel && useProxyMode) {
          successMessage = 'SSH tunnel (proxy) started on ${_vpnService.socksProxyAddress}';
        } else if (isSshTunnel && !useProxyMode) {
          successMessage = 'SSH tunnel (VPN) connected';
        } else if (useProxyMode || isDesktop) {
          successMessage = '$protocolName proxy started on ${_vpnService.socksProxyAddress}';
        } else {
          successMessage = '$protocolName VPN connected';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(successMessage),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        final error = _vpnService.lastError;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error != null
                ? 'Failed to start $connectionType: $error'
                : 'Failed to start $connectionType'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _disconnect(BuildContext context, AppState state) async {
    final isDesktop = VpnService.isDesktopPlatform;
    final wasProxyMode = _vpnService.isProxyMode;
    final wasSshTunnelMode = _vpnService.isSshTunnelMode;

    if (wasSshTunnelMode && !isDesktop) {
      await _vpnService.disconnectSshTunnel();
    } else if (wasProxyMode && !isDesktop) {
      await _vpnService.disconnectProxy();
    } else {
      await _vpnService.disconnect();
    }

    if (context.mounted) {
      String disconnectMessage;
      if (wasSshTunnelMode) {
        disconnectMessage = 'SSH tunnel stopped';
      } else if (isDesktop || wasProxyMode) {
        disconnectMessage = 'SOCKS proxy stopped';
      } else {
        disconnectMessage = 'VPN disconnected';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(disconnectMessage)),
      );
    }
  }

  Future<void> _cancelConnection(BuildContext context, AppState state) async {
    if (_vpnService.isSshTunnelMode && !VpnService.isDesktopPlatform) {
      await _vpnService.disconnectSshTunnel();
    } else if (_vpnService.isProxyMode && !VpnService.isDesktopPlatform) {
      await _vpnService.disconnectProxy();
    } else {
      await _vpnService.disconnect();
    }
    state.setConnectionStatus(ConnectionStatus.disconnected);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connection cancelled')),
      );
    }
  }
}
