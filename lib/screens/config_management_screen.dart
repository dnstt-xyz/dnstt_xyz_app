import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/dnstt_config.dart';
import '../services/config_import_export_service.dart';

class ConfigManagementScreen extends StatelessWidget {
  const ConfigManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DNSTT Configs'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'import_url') {
                _showImportFromUrlDialog(context);
              } else if (value == 'import_text') {
                _showImportFromTextDialog(context);
              } else if (value == 'export') {
                _exportConfigs(context);
              } else if (value == 'import_dnsttxyz') {
                _importFromDnsttXyz(context);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'import_url',
                child: Row(
                  children: [
                    Icon(Icons.cloud_download),
                    SizedBox(width: 8),
                    Text('Import from URL'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'import_text',
                child: Row(
                  children: [
                    Icon(Icons.paste),
                    SizedBox(width: 8),
                    Text('Import from JSON'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'import_dnsttxyz',
                child: Row(
                  children: [
                    Icon(Icons.public),
                    SizedBox(width: 8),
                    Text('Import from dnstt.xyz'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    Icon(Icons.share),
                    SizedBox(width: 8),
                    Text('Export Configs'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddConfigDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('Add Config'),
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          if (state.dnsttConfigs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.settings, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'No DNSTT Configs',
                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Add a config with public key and tunnel domain',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _showAddConfigDialog(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Add Config'),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: state.dnsttConfigs.length,
            itemBuilder: (context, index) {
              final config = state.dnsttConfigs[index];

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: InkWell(
                  onTap: () => state.setActiveConfig(config),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Radio<String>(
                              value: config.id,
                              groupValue: state.activeConfig?.id,
                              onChanged: (_) => state.setActiveConfig(config),
                              activeColor: Colors.green,
                            ),
                            Expanded(
                              child: Text(
                                config.name,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            PopupMenuButton(
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'edit',
                                  child: Row(
                                    children: [
                                      Icon(Icons.edit),
                                      SizedBox(width: 8),
                                      Text('Edit'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(Icons.delete, color: Colors.red),
                                      SizedBox(width: 8),
                                      Text('Delete',
                                          style: TextStyle(color: Colors.red)),
                                    ],
                                  ),
                                ),
                              ],
                              onSelected: (value) {
                                if (value == 'edit') {
                                  _showEditConfigDialog(context, config);
                                } else if (value == 'delete') {
                                  _confirmDelete(context, config);
                                }
                              },
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 48),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildDetailRow('Domain', config.tunnelDomain),
                              const SizedBox(height: 8),
                              _buildDetailRow(
                                'Public Key',
                                '${config.publicKey.substring(0, 16)}...',
                              ),
                              const SizedBox(height: 8),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  const SizedBox(
                                    width: 80,
                                    child: Text(
                                      'Type',
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: config.tunnelType == TunnelType.ssh
                                          ? Colors.purple[100]
                                          : Colors.blue[100],
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      config.tunnelType == TunnelType.ssh ? 'SSH' : 'Socks',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: config.tunnelType == TunnelType.ssh
                                            ? Colors.purple[700]
                                            : Colors.blue[700],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }

  void _showAddConfigDialog(BuildContext context) {
    _showConfigDialog(context, null);
  }

  void _showEditConfigDialog(BuildContext context, DnsttConfig config) {
    _showConfigDialog(context, config);
  }

  void _showConfigDialog(BuildContext context, DnsttConfig? existingConfig) {
    showDialog(
      context: context,
      builder: (context) => _ConfigDialog(existingConfig: existingConfig),
    );
  }

  void _confirmDelete(BuildContext context, DnsttConfig config) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Config?'),
        content: Text('Are you sure you want to delete "${config.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              context.read<AppState>().removeDnsttConfig(config.id);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // Import/Export methods

  void _showImportFromUrlDialog(BuildContext context) {
    final urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import from URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter a URL pointing to a JSON file with DNSTT configs:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'Config URL',
                hintText: 'https://example.com/configs.json',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final url = urlController.text.trim();
              if (url.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a URL')),
                );
                return;
              }

              Navigator.pop(context);

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
                          Text('Importing configs...'),
                        ],
                      ),
                    ),
                  ),
                ),
              );

              try {
                final configs = await ConfigImportExportService.importConfigsFromUrl(url);

                if (context.mounted) {
                  Navigator.pop(context); // Close loading dialog

                  if (configs.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('No valid configs found in URL')),
                    );
                    return;
                  }

                  final state = context.read<AppState>();
                  final result = await state.importDnsttConfigs(configs);

                  if (context.mounted) {
                    String message;
                    if (result.added > 0 && result.updated > 0) {
                      message = 'Added ${result.added} new configs, updated ${result.updated}';
                    } else if (result.added > 0) {
                      message = 'Imported ${result.added} new configs';
                    } else if (result.updated > 0) {
                      message = 'Updated ${result.updated} existing configs';
                    } else {
                      message = 'All configs already exist';
                    }

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(message), backgroundColor: Colors.green),
                    );
                  }
                }
              } catch (e) {
                if (context.mounted) {
                  Navigator.pop(context); // Close loading dialog
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Import failed: ${e.toString()}'),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  void _showImportFromTextDialog(BuildContext context) {
    final jsonController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import from JSON'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste your JSON config data:',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: jsonController,
                decoration: const InputDecoration(
                  labelText: 'JSON Data',
                  hintText: '{"configs": [...]}',
                  border: OutlineInputBorder(),
                ),
                maxLines: 10,
                autocorrect: false,
                enableSuggestions: false,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final jsonText = jsonController.text.trim();
              if (jsonText.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please paste JSON data')),
                );
                return;
              }

              Navigator.pop(context);

              try {
                final configs = ConfigImportExportService.importConfigsFromJson(jsonText);

                if (configs.isEmpty) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('No valid configs found in JSON')),
                    );
                  }
                  return;
                }

                final state = context.read<AppState>();
                final result = await state.importDnsttConfigs(configs);

                if (context.mounted) {
                  String message;
                  if (result.added > 0 && result.updated > 0) {
                    message = 'Added ${result.added} new configs, updated ${result.updated}';
                  } else if (result.added > 0) {
                    message = 'Imported ${result.added} new configs';
                  } else if (result.updated > 0) {
                    message = 'Updated ${result.updated} existing configs';
                  } else {
                    message = 'All configs already exist';
                  }

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(message), backgroundColor: Colors.green),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Import failed: ${e.toString()}'),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  void _exportConfigs(BuildContext context) {
    final state = context.read<AppState>();

    if (state.dnsttConfigs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No configs to export')),
      );
      return;
    }

    final jsonString = ConfigImportExportService.exportConfigsToJson(state.dnsttConfigs);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export Configs'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Exporting ${state.dnsttConfigs.length} configs:',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  jsonString,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: jsonString));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied to clipboard'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  void _importFromDnsttXyz(BuildContext context) async {
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

        if (result.configs.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No configs found on dnstt.xyz')),
          );
          return;
        }

        final state = context.read<AppState>();

        // Import configs
        final configResult = await state.importDnsttConfigs(result.configs);

        // Import DNS servers if any
        if (result.dnsServers.isNotEmpty) {
          await state.importDnsServers(result.dnsServers);
        }

        if (context.mounted) {
          String message = 'Imported ${configResult.added} configs';
          if (result.dnsServers.isNotEmpty) {
            message += ' and ${result.dnsServers.length} DNS servers';
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message), backgroundColor: Colors.green),
          );
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
}

/// Stateful dialog for adding/editing DNSTT configs with SSH tunnel support
class _ConfigDialog extends StatefulWidget {
  final DnsttConfig? existingConfig;

  const _ConfigDialog({this.existingConfig});

  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  late TextEditingController nameController;
  late TextEditingController publicKeyController;
  late TextEditingController domainController;
  late TextEditingController sshUsernameController;
  late TextEditingController sshPasswordController;

  late TunnelType selectedTunnelType;
  bool showPassword = false;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.existingConfig?.name ?? '');
    publicKeyController = TextEditingController(text: widget.existingConfig?.publicKey ?? '');
    domainController = TextEditingController(text: widget.existingConfig?.tunnelDomain ?? '');
    sshUsernameController = TextEditingController(text: widget.existingConfig?.sshUsername ?? '');
    sshPasswordController = TextEditingController(text: widget.existingConfig?.sshPassword ?? '');
    selectedTunnelType = widget.existingConfig?.tunnelType ?? TunnelType.socks5;
  }

  @override
  void dispose() {
    nameController.dispose();
    publicKeyController.dispose();
    domainController.dispose();
    sshUsernameController.dispose();
    sshPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existingConfig == null ? 'Add DNSTT Config' : 'Edit Config'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Config Name',
                hintText: 'e.g., My Server',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: publicKeyController,
              decoration: const InputDecoration(
                labelText: 'Public Key (64 hex chars)',
                hintText: 'Paste your public key here',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: domainController,
              decoration: const InputDecoration(
                labelText: 'Tunnel Domain',
                hintText: 'e.g., t.example.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildTypeTag(
                  label: 'Socks',
                  isSelected: selectedTunnelType == TunnelType.socks5,
                  onTap: () => setState(() => selectedTunnelType = TunnelType.socks5),
                ),
                const SizedBox(width: 8),
                _buildTypeTag(
                  label: 'SSH',
                  isSelected: selectedTunnelType == TunnelType.ssh,
                  onTap: () => setState(() => selectedTunnelType = TunnelType.ssh),
                ),
              ],
            ),
            if (selectedTunnelType == TunnelType.ssh) ...[
              const SizedBox(height: 16),
              const Text(
                'SSH Settings',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sshUsernameController,
                decoration: const InputDecoration(
                  labelText: 'SSH Username',
                  hintText: 'e.g., root',
                  border: OutlineInputBorder(),
                ),
                autocorrect: false,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: sshPasswordController,
                decoration: InputDecoration(
                  labelText: 'SSH Password',
                  hintText: 'Your SSH password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(showPassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: () {
                      setState(() {
                        showPassword = !showPassword;
                      });
                    },
                  ),
                ),
                obscureText: !showPassword,
                autocorrect: false,
                enableSuggestions: false,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saveConfig,
          child: Text(widget.existingConfig == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  Widget _buildTypeTag({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Theme.of(context).primaryColor : Colors.grey[200],
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey[700],
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  void _saveConfig() {
    final name = nameController.text.trim();
    final publicKey = publicKeyController.text.trim();
    final domain = domainController.text.trim();

    if (name.isEmpty || publicKey.isEmpty || domain.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all required fields')),
      );
      return;
    }

    if (publicKey.length != 64) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Public key must be 64 hex characters')),
      );
      return;
    }

    // Validate SSH settings if SSH type selected
    if (selectedTunnelType == TunnelType.ssh) {
      final sshUsername = sshUsernameController.text.trim();
      final sshPassword = sshPasswordController.text;

      if (sshUsername.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter SSH username')),
        );
        return;
      }

      if (sshPassword.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter SSH password')),
        );
        return;
      }
    }

    final state = context.read<AppState>();

    if (widget.existingConfig == null) {
      state.addDnsttConfig(DnsttConfig(
        name: name,
        publicKey: publicKey,
        tunnelDomain: domain,
        tunnelType: selectedTunnelType,
        sshUsername: selectedTunnelType == TunnelType.ssh ? sshUsernameController.text.trim() : null,
        sshPassword: selectedTunnelType == TunnelType.ssh ? sshPasswordController.text : null,
      ));
    } else {
      widget.existingConfig!.name = name;
      widget.existingConfig!.publicKey = publicKey;
      widget.existingConfig!.tunnelDomain = domain;
      widget.existingConfig!.tunnelType = selectedTunnelType;
      widget.existingConfig!.sshUsername = selectedTunnelType == TunnelType.ssh ? sshUsernameController.text.trim() : null;
      widget.existingConfig!.sshPassword = selectedTunnelType == TunnelType.ssh ? sshPasswordController.text : null;
      state.updateDnsttConfig(widget.existingConfig!);
    }

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(widget.existingConfig == null ? 'Config added' : 'Config updated'),
      ),
    );
  }
}
