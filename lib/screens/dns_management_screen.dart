import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/app_state.dart';
import '../models/dns_server.dart';
import '../services/vpn_service.dart';
import '../services/config_import_export_service.dart';
import '../services/bundled_dns_service.dart';

class DnsManagementScreen extends StatefulWidget {
  const DnsManagementScreen({super.key});

  @override
  State<DnsManagementScreen> createState() => _DnsManagementScreenState();
}

class _DnsManagementScreenState extends State<DnsManagementScreen> {
  final _searchController = TextEditingController();
  final VpnService _vpnService = VpnService();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _vpnService.init();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DNS Servers'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'add') {
                _showAddManuallyDialog(context);
              } else if (value == 'import') {
                _showImportDialog(context);
              } else if (value == 'export') {
                _exportDnsServers(context);
              } else if (value == 'delete_all') {
                _confirmClearAll(context);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'add',
                child: Row(
                  children: [
                    Icon(Icons.add),
                    SizedBox(width: 8),
                    Text('Add Manually'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'import',
                child: Row(
                  children: [
                    Icon(Icons.download),
                    SizedBox(width: 8),
                    Text('Import List'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    Icon(Icons.share),
                    SizedBox(width: 8),
                    Text('Export DNS Servers'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'delete_all',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Delete All', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search DNS servers...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
          ),
          // Auto DNS banner
          Consumer<AppState>(
            builder: (context, state, _) {
              if (!state.useAutoDns) return const SizedBox.shrink();
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.auto_fix_high, color: Colors.blue[700], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Local DNS is enabled (Beta)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          Text(
                            state.activeDns != null
                                ? 'Using system DNS: ${state.activeDns!.address}'
                                : state.autoDnsError ?? 'Detecting...',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => state.setUseAutoDns(false),
                      child: const Text('Disable'),
                    ),
                  ],
                ),
              );
            },
          ),
          // Test buttons row with progress
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Consumer<AppState>(
              builder: (context, state, _) {
                final hasServers = state.dnsServers.isNotEmpty;
                final isTestingAll = state.isTestingAll;
                final isTestingSupported = state.isTestingSupported;

                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: isTestingAll
                              ? ElevatedButton.icon(
                                  onPressed: () async {
                                    await state.cancelTesting();
                                  },
                                  icon: const Icon(Icons.stop),
                                  label: const Text('Cancel'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    foregroundColor: Colors.white,
                                  ),
                                )
                              : ElevatedButton.icon(
                                  onPressed: hasServers && isTestingSupported
                                      ? () => _testAllDnsServers(context)
                                      : hasServers && !isTestingSupported
                                          ? () => _showTestingNotSupportedError(context, state)
                                          : null,
                                  icon: const Icon(Icons.speed),
                                  label: const Text('Test All'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isTestingSupported ? Colors.blue : Colors.grey,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                        ),
                      ],
                    ),
                    // Progress indicator when testing
                    if (isTestingAll) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: state.testingTotal > 0
                            ? state.testingProgress / state.testingTotal
                            : null,
                        backgroundColor: Colors.grey[300],
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${state.testingProgress}/${state.testingTotal} tested • ${state.testingWorking} working • ${state.testingFailed} failed',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          // Config info banner
          Consumer<AppState>(
            builder: (context, state, _) {
              if (state.activeConfig == null) {
                return Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber, color: Colors.orange[700], size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Select a DNSTT config first to test DNS servers',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                );
              }
              // Show error banner if testing is not supported for this config type
              if (!state.isTestingSupported) {
                return Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red[700], size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              state.testingUnsupportedMessage,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.red[700],
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'DNS testing is only available for DNSTT SOCKS5 configs',
                              style: TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue[700], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Testing with: ${state.activeConfig!.name}',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: Consumer<AppState>(
              builder: (context, state, _) {
                final servers = _filterServers(state.dnsServers);

                if (servers.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.dns, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          'No DNS servers',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Import from list or add manually',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: servers.length,
                  itemBuilder: (context, index) {
                    final server = servers[index];
                    final isTesting = state.isDnsBeingTested(server.id);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        contentPadding: const EdgeInsets.only(left: 0, right: 8),
                        leading: Radio<String>(
                          value: server.id,
                          groupValue: state.useAutoDns ? null : state.activeDns?.id,
                          onChanged: state.useAutoDns ? null : (_) => state.setActiveDns(server),
                          activeColor: Colors.green,
                        ),
                        title: Row(
                          children: [
                            Text(
                              server.address,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w500,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Status indicator inline with IP
                            if (server.lastTested != null)
                              _buildStatusBadge(server),
                          ],
                        ),
                        subtitle: server.name != null
                            ? Text(
                                server.name!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                ),
                              )
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Test button
                            SizedBox(
                              width: 40,
                              height: 40,
                              child: isTesting
                                  ? const Center(
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      padding: EdgeInsets.zero,
                                      icon: Icon(
                                        Icons.speed,
                                        size: 22,
                                        color: state.isTestingSupported ? null : Colors.grey,
                                      ),
                                      onPressed: state.isTestingSupported
                                          ? () => _testSingleDns(context, server)
                                          : () => _showTestingNotSupportedError(context, state),
                                      tooltip: state.isTestingSupported
                                          ? 'Test this DNS'
                                          : state.testingUnsupportedMessage,
                                    ),
                            ),
                            // Delete button
                            SizedBox(
                              width: 40,
                              height: 40,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.delete_outline, size: 22),
                                onPressed: () => state.removeDnsServer(server.id),
                              ),
                            ),
                          ],
                        ),
                        onTap: state.useAutoDns ? null : () => state.setActiveDns(server),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(DnsServer server) {
    if (server.isWorking) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              server.lastLatencyMs != null ? '${server.lastLatencyMs}ms' : 'OK',
              style: const TextStyle(
                fontSize: 10,
                color: Colors.green,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    } else {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            const Text(
              'FAIL',
              style: TextStyle(
                fontSize: 10,
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }
  }

  List<DnsServer> _filterServers(List<DnsServer> servers) {
    if (_searchQuery.isEmpty) return servers;
    final query = _searchQuery.toLowerCase();
    return servers.where((s) {
      return s.address.contains(query) ||
          (s.name?.toLowerCase().contains(query) ?? false) ||
          (s.region?.toLowerCase().contains(query) ?? false) ||
          (s.provider?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  Future<void> _ensureVpnDisconnected() async {
    // Check if VPN is connected and disconnect it
    if (_vpnService.currentState == VpnState.connected ||
        _vpnService.currentState == VpnState.connecting) {
      await _vpnService.disconnect();
      // Small delay to ensure VPN is fully disconnected
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _testSingleDns(BuildContext context, DnsServer server) async {
    final state = context.read<AppState>();

    // Ensure VPN is disconnected before testing
    await _ensureVpnDisconnected();

    // Use AppState to handle testing (persists across screen changes)
    await state.testSingleDnsServer(server);
  }

  void _showTestingNotSupportedError(BuildContext context, AppState state) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red[700]),
            const SizedBox(width: 8),
            const Text('Testing Not Available'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              state.testingUnsupportedMessage,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'DNS server testing is only available for DNSTT SOCKS5 configurations.',
            ),
            const SizedBox(height: 8),
            const Text(
              'To test DNS servers, please select a DNSTT config with SOCKS5 tunnel type (not SSH).',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _testAllDnsServers(BuildContext context) async {
    final state = context.read<AppState>();

    if (state.dnsServers.isEmpty) return;

    // Show confirmation dialog with test URL option
    final shouldStart = await _showTestConfirmationDialog(context, state);
    if (shouldStart != true) return;

    // Ensure VPN is disconnected before testing
    await _ensureVpnDisconnected();

    final tunnelDomain = state.activeConfig?.tunnelDomain;
    final testType = tunnelDomain != null ? 'tunnel test' : 'basic DNS test';

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Starting $testType for ${state.dnsServers.length} servers...'),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    // Use AppState to handle testing (persists across screen changes)
    await state.startTestingAllDnsServers();
  }

  Future<bool?> _showTestConfirmationDialog(BuildContext context, AppState state) async {
    final urlController = TextEditingController(text: state.testUrl);

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Test DNS Servers'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will test ${state.dnsServers.length} DNS servers by connecting through the DNSTT tunnel and making an HTTP request.',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'Test URL',
                hintText: 'https://api.ipify.org?format=json',
                border: OutlineInputBorder(),
                helperText: 'URL to fetch through the tunnel',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            if (state.activeConfig != null)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.blue, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Using config: ${state.activeConfig!.name}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning, color: Colors.orange, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'No config selected. Will use basic DNS test.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final newUrl = urlController.text.trim();
              if (newUrl.isNotEmpty && newUrl != state.testUrl) {
                state.setTestUrl(newUrl);
              }
              Navigator.pop(context, true);
            },
            child: const Text('Start Test'),
          ),
        ],
      ),
    );
  }

  void _showImportDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (sheetContext, scrollController) => FutureBuilder<List<DnsCountryData>>(
          future: BundledDnsService().loadAllCountries(),
          builder: (_, snapshot) {
            final countries = snapshot.data ?? [];
            final isLoading = snapshot.connectionState == ConnectionState.waiting;

            return Padding(
              padding: const EdgeInsets.all(20),
              child: ListView(
                controller: scrollController,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.download, size: 28),
                      const SizedBox(width: 12),
                      Text(
                        'Import DNS Servers',
                        style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Select a country to import DNS servers (${countries.fold<int>(0, (sum, c) => sum + c.servers.length)} total)',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 20),
                  // Import from URL - First option
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: Colors.purple.withOpacity(0.1),
                    child: ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.purple.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.link, color: Colors.purple),
                      ),
                      title: const Text(
                        'Import from URL',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text('Fetch DNS servers from a JSON URL'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _showImportFromUrlDialog(context);
                      },
                    ),
                  ),
                  // Import from File
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: Colors.indigo.withOpacity(0.1),
                    child: ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.indigo.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.file_open, color: Colors.indigo),
                      ),
                      title: const Text(
                        'Import from File',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text('Load DNS servers from a JSON file'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _importFromFile(context);
                      },
                    ),
                  ),
                  // Import from Clipboard
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: Colors.teal.withOpacity(0.1),
                    child: ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.teal.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.content_paste, color: Colors.teal),
                      ),
                      title: const Text(
                        'Import from Clipboard',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text('Paste JSON from clipboard'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _importFromClipboard(context);
                      },
                    ),
                  ),
                  // Import All
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: Colors.green.withOpacity(0.1),
                    child: ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.public, color: Colors.green),
                      ),
                      title: const Text(
                        'Import All Countries',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text('${countries.fold<int>(0, (sum, c) => sum + c.servers.length)} servers from ${countries.length} countries'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _importAllCountries(context, countries);
                      },
                    ),
                  ),
                  const Divider(),
                  Text(
                    'Select by Country',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (isLoading)
                    const Center(child: CircularProgressIndicator())
                  else
                    ...countries.map((country) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: Text(
                                  BundledDnsService.getFlagEmoji(country.countryCode),
                                  style: const TextStyle(fontSize: 24),
                                ),
                              ),
                            ),
                            title: Text(
                              country.country,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text('${country.servers.length} servers'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _importCountryDns(context, country);
                            },
                          ),
                        )),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _importCountryDns(BuildContext context, DnsCountryData country) async {
    final state = context.read<AppState>();
    final result = await state.importDnsServers(country.servers);

    if (context.mounted) {
      String message;
      if (result.added > 0 && result.updated > 0) {
        message = 'Added ${result.added} new servers, updated ${result.updated} existing';
      } else if (result.added > 0) {
        message = 'Added ${result.added} DNS servers from ${country.country}';
      } else if (result.updated > 0) {
        message = 'Updated ${result.updated} existing servers';
      } else {
        message = 'All servers from ${country.country} already imported';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _importAllCountries(BuildContext context, List<DnsCountryData> countries) async {
    final state = context.read<AppState>();
    int totalAdded = 0;
    int totalUpdated = 0;

    for (final country in countries) {
      final result = await state.importDnsServers(country.servers);
      totalAdded += result.added;
      totalUpdated += result.updated;
    }

    if (context.mounted) {
      String message;
      if (totalAdded > 0 && totalUpdated > 0) {
        message = 'Added $totalAdded new servers, updated $totalUpdated existing';
      } else if (totalAdded > 0) {
        message = 'Added $totalAdded DNS servers from ${countries.length} countries';
      } else if (totalUpdated > 0) {
        message = 'Updated $totalUpdated existing servers';
      } else {
        message = 'All servers already imported';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: totalAdded > 0 ? Colors.green : null,
        ),
      );
    }
  }

  void _showAddManuallyDialog(BuildContext context) {
    final ipController = TextEditingController();
    final nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add DNS Server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'IP Address *',
                hintText: 'e.g., 8.8.8.8',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.text,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                hintText: 'e.g., Google DNS',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.text,
            ),
            const SizedBox(height: 8),
            Text(
              'IP address is required. Name is optional.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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
              final ip = ipController.text.trim();
              final name = nameController.text.trim();

              if (ip.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter an IP address')),
                );
                return;
              }

              // Basic IP validation
              final ipRegex = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
              if (!ipRegex.hasMatch(ip)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invalid IP address format')),
                );
                return;
              }

              final state = context.read<AppState>();
              state.addDnsServer(DnsServer(
                address: ip,
                name: name.isNotEmpty ? name : null,
              ));

              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('DNS server added')),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _confirmClearAll(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All DNS Servers?'),
        content: const Text('This will remove all imported DNS servers.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              context.read<AppState>().clearAllDnsServers();
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }

  Future<void> _importFromDnsttXyz(BuildContext context) async {
    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Fetching servers from dnstt.xyz...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final result = await ConfigImportExportService.fetchDnsttXyzServers();

      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog

        final state = context.read<AppState>();

        // Import configs
        int totalConfigs = 0;
        if (result.configs.isNotEmpty) {
          final configResult = await state.importDnsttConfigs(result.configs);
          totalConfigs = configResult.added;
        }

        // Import DNS servers
        int totalDns = 0;
        if (result.dnsServers.isNotEmpty) {
          final dnsResult = await state.importDnsServers(result.dnsServers);
          totalDns = dnsResult.added;
        }

        if (context.mounted) {
          if (totalConfigs == 0 && totalDns == 0) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('No new servers found on dnstt.xyz'),
              ),
            );
          } else {
            String message = '';
            if (totalDns > 0) {
              message = 'Imported $totalDns DNS servers';
            }
            if (totalConfigs > 0) {
              if (message.isNotEmpty) message += ' and ';
              message += '$totalConfigs DNSTT configs';
            }

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message),
                backgroundColor: Colors.green,
                action: totalConfigs > 0
                    ? SnackBarAction(
                        label: 'View Configs',
                        textColor: Colors.white,
                        onPressed: () {
                          Navigator.pop(context); // Go back to previous screen
                        },
                      )
                    : null,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to fetch from dnstt.xyz: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  void _showImportFromUrlDialog(BuildContext context) {
    final urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import from URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter a URL to a JSON file containing DNS servers.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              'Expected format: {"servers": [{"ip": "1.2.3.4", "name": "My DNS"}]}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://example.com/dns.json',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final url = urlController.text.trim();
              if (url.isEmpty) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Please enter a URL')),
                );
                return;
              }

              if (!url.startsWith('http://') && !url.startsWith('https://')) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('URL must start with http:// or https://')),
                );
                return;
              }

              Navigator.pop(dialogContext);
              _importFromUrl(context, url);
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  Future<void> _importFromUrl(BuildContext context, String url) async {
    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Fetching DNS servers...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final servers = await ConfigImportExportService.importDnsServersFromUrl(url);

      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog

        if (servers.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No valid DNS servers found in the response'),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }

        final state = context.read<AppState>();
        final result = await state.importDnsServers(servers);

        if (context.mounted) {
          String message;
          if (result.added > 0 && result.updated > 0) {
            message = 'Added ${result.added} new servers, updated ${result.updated} existing';
          } else if (result.added > 0) {
            message = 'Added ${result.added} new DNS servers';
          } else if (result.updated > 0) {
            message = 'Updated ${result.updated} existing servers';
          } else {
            message = 'All servers already imported';
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: result.added > 0 ? Colors.green : null,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to import: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _exportDnsServers(BuildContext context) async {
    final state = context.read<AppState>();

    if (state.dnsServers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No DNS servers to export')),
      );
      return;
    }

    final jsonString = ConfigImportExportService.exportDnsServersToJson(state.dnsServers);

    // On desktop, directly open native save dialog
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      _saveJsonFile(context, jsonString, 'dns_servers.json');
      return;
    }

    // On mobile, show bottom sheet with Share and Save options
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Export ${state.dnsServers.length} DNS Servers',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('Share'),
                subtitle: const Text('Send via apps, AirDrop, etc.'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _shareJsonFile(context, jsonString, 'dns_servers.json', 'DNS Servers');
                },
              ),
              ListTile(
                leading: const Icon(Icons.save),
                title: const Text('Save to File'),
                subtitle: const Text('Save JSON file to device'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _saveJsonFile(context, jsonString, 'dns_servers.json');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareJsonFile(BuildContext context, String jsonString, String fileName, String subject) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(jsonString);

      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: subject,
        sharePositionOrigin: box != null
            ? box.localToGlobal(Offset.zero) & box.size
            : null,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _saveJsonFile(BuildContext context, String jsonString, String fileName) async {
    try {
      final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      final bytes = utf8.encode(jsonString);

      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save $fileName',
        fileName: fileName,
        type: isDesktop ? FileType.any : FileType.custom,
        allowedExtensions: isDesktop ? null : ['json'],
        bytes: isDesktop ? null : Uint8List.fromList(bytes),
      );

      if (result != null) {
        if (isDesktop) {
          await File(result).writeAsString(jsonString);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved to file'), backgroundColor: Colors.green),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _importFromClipboard(BuildContext context) async {
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text?.trim();

      if (text == null || text.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Clipboard is empty')),
          );
        }
        return;
      }

      final servers = ConfigImportExportService.importDnsServersFromJson(text);

      if (servers.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No valid DNS servers found in clipboard'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final state = context.read<AppState>();
      final importResult = await state.importDnsServers(servers);

      if (context.mounted) {
        String message;
        if (importResult.added > 0 && importResult.updated > 0) {
          message = 'Added ${importResult.added} new servers, updated ${importResult.updated} existing';
        } else if (importResult.added > 0) {
          message = 'Added ${importResult.added} new DNS servers';
        } else if (importResult.updated > 0) {
          message = 'Updated ${importResult.updated} existing servers';
        } else {
          message = 'All servers already imported';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: importResult.added > 0 ? Colors.green : null,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to import from clipboard: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _importFromFile(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;
      String jsonString;

      if (file.bytes != null) {
        jsonString = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        jsonString = await File(file.path!).readAsString();
      } else {
        throw Exception('Could not read file');
      }

      final servers = ConfigImportExportService.importDnsServersFromJson(jsonString);

      if (servers.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No valid DNS servers found in file'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final state = context.read<AppState>();
      final importResult = await state.importDnsServers(servers);

      if (context.mounted) {
        String message;
        if (importResult.added > 0 && importResult.updated > 0) {
          message = 'Added ${importResult.added} new servers, updated ${importResult.updated} existing';
        } else if (importResult.added > 0) {
          message = 'Added ${importResult.added} new DNS servers';
        } else if (importResult.updated > 0) {
          message = 'Updated ${importResult.updated} existing servers';
        } else {
          message = 'All servers already imported';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: importResult.added > 0 ? Colors.green : null,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to import: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }
}
