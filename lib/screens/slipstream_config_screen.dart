import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/slipstream_config.dart';

class SlipstreamConfigScreen extends StatelessWidget {
  const SlipstreamConfigScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Slipstream Configs'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddConfigDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('Add Config'),
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          if (state.slipstreamConfigs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bolt, size: 64, color: Colors.orange[300]),
                  const SizedBox(height: 16),
                  Text(
                    'No Slipstream Configs',
                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Add a config with tunnel domain',
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
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: state.slipstreamConfigs.length,
            itemBuilder: (context, index) {
              final config = state.slipstreamConfigs[index];
              final isActive = state.activeSlipstreamConfig?.id == config.id;

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isActive ? Colors.orange : Colors.grey[300],
                    child: Icon(
                      Icons.bolt,
                      color: isActive ? Colors.white : Colors.grey[600],
                    ),
                  ),
                  title: Text(
                    config.name,
                    style: TextStyle(
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    config.tunnelDomain +
                        (config.resolver != null ? '\nResolver: ${config.resolver}' : '\nUsing selected DNS'),
                  ),
                  isThreeLine: config.resolver != null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isActive)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Chip(
                            label: Text('Active', style: TextStyle(fontSize: 12)),
                            backgroundColor: Colors.orange,
                            labelStyle: TextStyle(color: Colors.white),
                            padding: EdgeInsets.zero,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            _showEditConfigDialog(context, config);
                          } else if (value == 'delete') {
                            _confirmDelete(context, config);
                          }
                        },
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
                                Text('Delete', style: TextStyle(color: Colors.red)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  onTap: () {
                    context.read<AppState>().setActiveSlipstreamConfig(config);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Selected: ${config.name}'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showAddConfigDialog(BuildContext context) {
    _showConfigDialog(context, null);
  }

  void _showEditConfigDialog(BuildContext context, SlipstreamConfig config) {
    _showConfigDialog(context, config);
  }

  void _showConfigDialog(BuildContext context, SlipstreamConfig? existingConfig) {
    final nameController = TextEditingController(text: existingConfig?.name ?? '');
    final domainController = TextEditingController(text: existingConfig?.tunnelDomain ?? '');
    final resolverController = TextEditingController(text: existingConfig?.resolver ?? '');
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existingConfig == null ? 'Add Slipstream Config' : 'Edit Config'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'My Slipstream Server',
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Name is required';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: domainController,
                  decoration: const InputDecoration(
                    labelText: 'Tunnel Domain *',
                    hintText: 'tunnel.example.com',
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Tunnel domain is required';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: resolverController,
                  decoration: const InputDecoration(
                    labelText: 'Resolver (optional)',
                    hintText: 'Leave empty to use selected DNS',
                    helperText: 'e.g., 8.8.8.8 or 1.1.1.1:53',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                final config = SlipstreamConfig(
                  id: existingConfig?.id,
                  name: nameController.text.trim(),
                  tunnelDomain: domainController.text.trim(),
                  resolver: resolverController.text.trim().isEmpty
                      ? null
                      : resolverController.text.trim(),
                );

                if (existingConfig == null) {
                  context.read<AppState>().addSlipstreamConfig(config);
                } else {
                  context.read<AppState>().updateSlipstreamConfig(config);
                }

                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(existingConfig == null ? 'Config added' : 'Config updated'),
                  ),
                );
              }
            },
            child: Text(existingConfig == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, SlipstreamConfig config) {
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
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              context.read<AppState>().removeSlipstreamConfig(config.id);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Config deleted')),
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
