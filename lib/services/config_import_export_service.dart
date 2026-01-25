import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/dnstt_config.dart';
import '../models/dns_server.dart';

class ConfigImportExportService {
  /// Import DNSTT configs from a JSON URL
  /// Expected JSON format:
  /// {
  ///   "version": "1.0",
  ///   "configs": [
  ///     {
  ///       "name": "Server Name",
  ///       "publicKey": "64_char_hex_key",
  ///       "tunnelDomain": "tunnel.example.com"
  ///     }
  ///   ]
  /// }
  static Future<List<DnsttConfig>> importConfigsFromUrl(String url) async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'DNSTT-Client/1.0',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch configs: HTTP ${response.statusCode}');
      }

      final jsonData = json.decode(response.body);

      // Handle array format (direct list of configs)
      if (jsonData is List) {
        return _parseConfigList(jsonData);
      }

      // Handle object format with configs array
      if (jsonData is Map<String, dynamic> && jsonData.containsKey('configs')) {
        final configsList = jsonData['configs'] as List;
        return _parseConfigList(configsList);
      }

      throw Exception('Invalid JSON format. Expected array or object with "configs" field.');
    } catch (e) {
      throw Exception('Failed to import configs: $e');
    }
  }

  /// Parse a list of config JSON objects
  static List<DnsttConfig> _parseConfigList(List configsList) {
    final configs = <DnsttConfig>[];

    for (final item in configsList) {
      if (item is! Map<String, dynamic>) continue;

      try {
        // Parse tunnel type (socks5 or ssh)
        TunnelType tunnelType = TunnelType.socks5;
        final typeStr = item['tunnelType']?.toString().toLowerCase() ??
                        item['type']?.toString().toLowerCase() ?? 'socks5';
        if (typeStr == 'ssh') {
          tunnelType = TunnelType.ssh;
        }

        final config = DnsttConfig(
          name: item['name']?.toString() ?? 'Unnamed Config',
          publicKey: item['publicKey']?.toString() ?? item['pubkey']?.toString() ?? '',
          tunnelDomain: item['tunnelDomain']?.toString() ?? item['domain']?.toString() ?? '',
          tunnelType: tunnelType,
          sshUsername: item['sshUsername']?.toString(),
          sshPassword: item['sshPassword']?.toString(),
          sshPrivateKey: item['sshPrivateKey']?.toString(),
        );

        if (config.isValid) {
          configs.add(config);
        }
      } catch (e) {
        // Skip invalid configs
        continue;
      }
    }

    return configs;
  }

  /// Import configs from JSON string
  static List<DnsttConfig> importConfigsFromJson(String jsonString) {
    try {
      final jsonData = json.decode(jsonString);

      if (jsonData is List) {
        return _parseConfigList(jsonData);
      }

      if (jsonData is Map<String, dynamic> && jsonData.containsKey('configs')) {
        final configsList = jsonData['configs'] as List;
        return _parseConfigList(configsList);
      }

      throw Exception('Invalid JSON format');
    } catch (e) {
      throw Exception('Failed to parse JSON: $e');
    }
  }

  /// Export configs to JSON string
  static String exportConfigsToJson(List<DnsttConfig> configs) {
    final data = {
      'version': '1.2',
      'configs': configs.map((c) {
        final configMap = <String, dynamic>{
          'name': c.name,
          'publicKey': c.publicKey,
          'tunnelDomain': c.tunnelDomain,
          'tunnelType': c.tunnelType.name,        // socks5 or ssh
        };

        // Include SSH settings only for SSH tunnel type
        if (c.tunnelType == TunnelType.ssh) {
          if (c.sshUsername != null) configMap['sshUsername'] = c.sshUsername;
          if (c.sshPassword != null) configMap['sshPassword'] = c.sshPassword;
          // Note: For security, we don't export sshPrivateKey
          // It should be entered manually after import
        }

        return configMap;
      }).toList(),
    };

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Fetch DNSTT servers from dnstt.xyz
  /// Returns a tuple of (configs, dnsServers)
  static Future<({List<DnsttConfig> configs, List<DnsServer> dnsServers})> fetchDnsttXyzServers() async {
    const url = 'https://dnstt.xyz/servers/dnstt-servers.json';

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'DNSTT-Client/1.0',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch servers: HTTP ${response.statusCode}');
      }

      final jsonData = json.decode(response.body);

      if (jsonData is! List) {
        throw Exception('Invalid response format');
      }

      final configs = <DnsttConfig>[];
      final dnsServers = <DnsServer>[];

      for (final item in jsonData) {
        if (item is! Map<String, dynamic>) continue;

        try {
          final name = item['name']?.toString() ?? 'DNSTT Server';
          final domain = item['domain']?.toString() ?? '';
          final pubkey = item['pubkey']?.toString() ?? '';

          if (domain.isNotEmpty && pubkey.isNotEmpty && pubkey.length == 64) {
            // Create config
            final config = DnsttConfig(
              name: name,
              publicKey: pubkey,
              tunnelDomain: domain,
            );
            configs.add(config);

            // Extract DNS servers from user field if present
            // Format: user@dns_server or just dns_server
            final user = item['user']?.toString() ?? '';
            if (user.isNotEmpty) {
              // Extract DNS IP from user field (format: username@dns_ip)
              final parts = user.split('@');
              if (parts.length == 2) {
                final dnsIp = parts[1];
                // Validate IP format
                if (_isValidIp(dnsIp)) {
                  dnsServers.add(DnsServer(
                    address: dnsIp,
                    name: '$name DNS',
                    provider: 'dnstt.xyz',
                  ));
                }
              }
            }
          }
        } catch (e) {
          // Skip invalid entries
          continue;
        }
      }

      return (configs: configs, dnsServers: dnsServers);
    } catch (e) {
      throw Exception('Failed to fetch dnstt.xyz servers: $e');
    }
  }

  /// Simple IP validation
  static bool _isValidIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;

    for (final part in parts) {
      final num = int.tryParse(part);
      if (num == null || num < 0 || num > 255) return false;
    }

    return true;
  }

  /// Export DNS servers to JSON string
  static String exportDnsServersToJson(List<DnsServer> servers) {
    final data = {
      'version': '1.0',
      'servers': servers.map((s) => {
        'ip': s.address,
        if (s.name != null) 'name': s.name,
        if (s.provider != null) 'provider': s.provider,
        if (s.region != null) 'region': s.region,
      }).toList(),
    };

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Import DNS servers from a JSON URL
  static Future<List<DnsServer>> importDnsServersFromUrl(String url) async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'DNSTT-Client/1.0',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final jsonData = json.decode(response.body);
      return _parseDnsServerList(jsonData);
    } on TimeoutException {
      throw Exception('Request timed out after 15 seconds');
    } on http.ClientException catch (e) {
      throw Exception('Network error: $e');
    } on FormatException catch (e) {
      throw Exception('Invalid JSON format: $e');
    } catch (e) {
      throw Exception('Failed to fetch: $e');
    }
  }

  /// Parse DNS server list from JSON
  static List<DnsServer> _parseDnsServerList(dynamic jsonData) {
    final servers = <DnsServer>[];
    List serversList;

    // Handle array format (direct list)
    if (jsonData is List) {
      serversList = jsonData;
    }
    // Handle object format with servers array
    else if (jsonData is Map<String, dynamic> && jsonData.containsKey('servers')) {
      serversList = jsonData['servers'] as List;
    }
    else {
      throw Exception('Invalid JSON format. Expected array or object with "servers" field.');
    }

    for (final item in serversList) {
      if (item is! Map<String, dynamic>) continue;

      try {
        final ip = item['ip']?.toString() ?? item['address']?.toString() ?? '';
        if (ip.isEmpty || !_isValidIp(ip)) continue;

        servers.add(DnsServer(
          address: ip,
          name: item['name']?.toString(),
          provider: item['provider']?.toString(),
          region: item['region']?.toString(),
        ));
      } catch (e) {
        // Skip invalid entries
        continue;
      }
    }

    return servers;
  }
}
