import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/dns_server.dart';
import '../models/dnstt_config.dart';
import '../models/slipstream_config.dart';

class StorageService {
  static const String _dnsServersKey = 'dns_servers';
  static const String _dnsttConfigsKey = 'dnstt_configs';
  static const String _slipstreamConfigsKey = 'slipstream_configs';
  static const String _activeConfigKey = 'active_config';
  static const String _activeSlipstreamConfigKey = 'active_slipstream_config';
  static const String _activeDnsKey = 'active_dns';
  static const String _testUrlKey = 'test_url';
  static const String _proxyPortKey = 'proxy_port';
  static const int defaultProxyPort = 1080;

  final SharedPreferences _prefs;

  StorageService(this._prefs);

  static Future<StorageService> init() async {
    final prefs = await SharedPreferences.getInstance();
    return StorageService(prefs);
  }

  // DNS Servers
  Future<List<DnsServer>> getDnsServers() async {
    final jsonStr = _prefs.getString(_dnsServersKey);
    if (jsonStr == null) return [];
    final List<dynamic> jsonList = json.decode(jsonStr);
    return jsonList.map((j) => DnsServer.fromJson(j)).toList();
  }

  Future<void> saveDnsServers(List<DnsServer> servers) async {
    final jsonStr = json.encode(servers.map((s) => s.toJson()).toList());
    await _prefs.setString(_dnsServersKey, jsonStr);
  }

  Future<void> addDnsServer(DnsServer server) async {
    final servers = await getDnsServers();
    if (!servers.contains(server)) {
      servers.add(server);
      await saveDnsServers(servers);
    }
  }

  Future<void> removeDnsServer(String id) async {
    final servers = await getDnsServers();
    servers.removeWhere((s) => s.id == id);
    await saveDnsServers(servers);
  }

  Future<void> updateDnsServer(DnsServer server) async {
    final servers = await getDnsServers();
    final index = servers.indexWhere((s) => s.id == server.id);
    if (index != -1) {
      servers[index] = server;
      await saveDnsServers(servers);
    }
  }

  // DNSTT Configs
  Future<List<DnsttConfig>> getDnsttConfigs() async {
    final jsonStr = _prefs.getString(_dnsttConfigsKey);
    if (jsonStr == null) return [];
    final List<dynamic> jsonList = json.decode(jsonStr);
    return jsonList.map((j) => DnsttConfig.fromJson(j)).toList();
  }

  Future<void> saveDnsttConfigs(List<DnsttConfig> configs) async {
    final jsonStr = json.encode(configs.map((c) => c.toJson()).toList());
    await _prefs.setString(_dnsttConfigsKey, jsonStr);
  }

  Future<void> addDnsttConfig(DnsttConfig config) async {
    final configs = await getDnsttConfigs();
    configs.add(config);
    await saveDnsttConfigs(configs);
  }

  Future<void> removeDnsttConfig(String id) async {
    final configs = await getDnsttConfigs();
    configs.removeWhere((c) => c.id == id);
    await saveDnsttConfigs(configs);
  }

  Future<void> updateDnsttConfig(DnsttConfig config) async {
    final configs = await getDnsttConfigs();
    final index = configs.indexWhere((c) => c.id == config.id);
    if (index != -1) {
      configs[index] = config;
      await saveDnsttConfigs(configs);
    }
  }

  // Active selections
  Future<String?> getActiveConfigId() async {
    return _prefs.getString(_activeConfigKey);
  }

  Future<void> setActiveConfigId(String? id) async {
    if (id == null) {
      await _prefs.remove(_activeConfigKey);
    } else {
      await _prefs.setString(_activeConfigKey, id);
    }
  }

  Future<String?> getActiveDnsId() async {
    return _prefs.getString(_activeDnsKey);
  }

  Future<void> setActiveDnsId(String? id) async {
    if (id == null) {
      await _prefs.remove(_activeDnsKey);
    } else {
      await _prefs.setString(_activeDnsKey, id);
    }
  }

  // Test URL
  Future<String?> getTestUrl() async {
    return _prefs.getString(_testUrlKey);
  }

  Future<void> setTestUrl(String url) async {
    await _prefs.setString(_testUrlKey, url);
  }

  // Proxy Port
  Future<int> getProxyPort() async {
    return _prefs.getInt(_proxyPortKey) ?? defaultProxyPort;
  }

  Future<void> setProxyPort(int port) async {
    await _prefs.setInt(_proxyPortKey, port);
  }

  // Slipstream Configs
  Future<List<SlipstreamConfig>> getSlipstreamConfigs() async {
    final jsonStr = _prefs.getString(_slipstreamConfigsKey);
    if (jsonStr == null) return [];
    final List<dynamic> jsonList = json.decode(jsonStr);
    return jsonList.map((j) => SlipstreamConfig.fromJson(j)).toList();
  }

  Future<void> saveSlipstreamConfigs(List<SlipstreamConfig> configs) async {
    final jsonStr = json.encode(configs.map((c) => c.toJson()).toList());
    await _prefs.setString(_slipstreamConfigsKey, jsonStr);
  }

  Future<void> addSlipstreamConfig(SlipstreamConfig config) async {
    final configs = await getSlipstreamConfigs();
    configs.add(config);
    await saveSlipstreamConfigs(configs);
  }

  Future<void> removeSlipstreamConfig(String id) async {
    final configs = await getSlipstreamConfigs();
    configs.removeWhere((c) => c.id == id);
    await saveSlipstreamConfigs(configs);
  }

  Future<void> updateSlipstreamConfig(SlipstreamConfig config) async {
    final configs = await getSlipstreamConfigs();
    final index = configs.indexWhere((c) => c.id == config.id);
    if (index != -1) {
      configs[index] = config;
      await saveSlipstreamConfigs(configs);
    }
  }

  // Active Slipstream Config
  Future<String?> getActiveSlipstreamConfigId() async {
    return _prefs.getString(_activeSlipstreamConfigKey);
  }

  Future<void> setActiveSlipstreamConfigId(String? id) async {
    if (id == null) {
      await _prefs.remove(_activeSlipstreamConfigKey);
    } else {
      await _prefs.setString(_activeSlipstreamConfigKey, id);
    }
  }
}
