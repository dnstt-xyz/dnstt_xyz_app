import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/dns_server.dart';

class DnsCountryData {
  final String country;
  final String countryCode;
  final String description;
  final List<DnsServer> servers;

  DnsCountryData({
    required this.country,
    required this.countryCode,
    required this.description,
    required this.servers,
  });

  factory DnsCountryData.fromJson(Map<String, dynamic> json) {
    final servers = (json['servers'] as List).map((s) {
      return DnsServer(
        address: s['ip'] as String,
        name: s['name'] as String?,
        region: json['country'] as String?,
        provider: json['countryCode'] as String?,
      );
    }).toList();

    return DnsCountryData(
      country: json['country'] as String? ?? 'Unknown',
      countryCode: json['countryCode'] as String? ?? 'xx',
      description: json['description'] as String? ?? '',
      servers: servers,
    );
  }
}

class BundledDnsService {
  static final BundledDnsService _instance = BundledDnsService._internal();
  factory BundledDnsService() => _instance;
  BundledDnsService._internal();

  List<DnsCountryData>? _cachedData;

  /// Get list of available country files
  static const List<String> _countryFiles = [
    'ae', 'af', 'bd', 'cn', 'co', 'id', 'ir', 'kw', 'pk', 'qa', 'ru', 'sy', 'tr', 'ug', 'uz'
  ];

  /// Country code to flag emoji mapping
  static String getFlagEmoji(String countryCode) {
    final code = countryCode.toUpperCase();
    if (code.length != 2) return '';

    final firstLetter = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final secondLetter = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCodes([firstLetter, secondLetter]);
  }

  /// Load all bundled DNS data
  Future<List<DnsCountryData>> loadAllCountries() async {
    if (_cachedData != null) return _cachedData!;

    final List<DnsCountryData> countries = [];

    for (final code in _countryFiles) {
      try {
        final jsonStr = await rootBundle.loadString('assets/dns/$code.json');
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        countries.add(DnsCountryData.fromJson(json));
      } catch (e) {
        print('Error loading DNS data for $code: $e');
      }
    }

    // Sort by country name
    countries.sort((a, b) => a.country.compareTo(b.country));
    _cachedData = countries;
    return countries;
  }

  /// Load DNS data for a specific country
  Future<DnsCountryData?> loadCountry(String countryCode) async {
    try {
      final jsonStr = await rootBundle.loadString('assets/dns/$countryCode.json');
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return DnsCountryData.fromJson(json);
    } catch (e) {
      print('Error loading DNS data for $countryCode: $e');
      return null;
    }
  }

  /// Clear cache
  void clearCache() {
    _cachedData = null;
  }
}
