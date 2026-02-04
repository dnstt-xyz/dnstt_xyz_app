import 'package:uuid/uuid.dart';

/// Configuration for Slipstream (QUIC-over-DNS) tunnel
class SlipstreamConfig {
  final String id;
  String name;
  String tunnelDomain;

  /// Optional resolver address (e.g., "8.8.8.8" or "1.1.1.1:53")
  /// If null, uses the app's selected DNS server
  String? resolver;

  /// Whether to use authoritative mode (direct to server vs recursive resolver)
  bool authoritative;

  SlipstreamConfig({
    String? id,
    required this.name,
    required this.tunnelDomain,
    this.resolver,
    this.authoritative = false,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tunnelDomain': tunnelDomain,
        'resolver': resolver,
        'authoritative': authoritative,
      };

  factory SlipstreamConfig.fromJson(Map<String, dynamic> json) => SlipstreamConfig(
        id: json['id'],
        name: json['name'],
        tunnelDomain: json['tunnelDomain'],
        resolver: json['resolver'],
        authoritative: json['authoritative'] ?? false,
      );
}
