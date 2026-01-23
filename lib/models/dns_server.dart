import 'package:uuid/uuid.dart';

class DnsServer {
  final String id;
  final String address;
  final String? name;
  final String? region;
  final String? provider;
  bool isWorking;
  DateTime? lastTested;
  int? lastLatencyMs;
  String? lastTestMessage;

  DnsServer({
    String? id,
    required this.address,
    this.name,
    this.region,
    this.provider,
    this.isWorking = false,
    this.lastTested,
    this.lastLatencyMs,
    this.lastTestMessage,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'address': address,
        'name': name,
        'region': region,
        'provider': provider,
        'isWorking': isWorking,
        'lastTested': lastTested?.toIso8601String(),
        'lastLatencyMs': lastLatencyMs,
        'lastTestMessage': lastTestMessage,
      };

  factory DnsServer.fromJson(Map<String, dynamic> json) => DnsServer(
        id: json['id'],
        address: json['address'],
        name: json['name'],
        region: json['region'],
        provider: json['provider'],
        isWorking: json['isWorking'] ?? false,
        lastTested: json['lastTested'] != null
            ? DateTime.parse(json['lastTested'])
            : null,
        lastLatencyMs: json['lastLatencyMs'],
        lastTestMessage: json['lastTestMessage'],
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DnsServer &&
          runtimeType == other.runtimeType &&
          address == other.address;

  @override
  int get hashCode => address.hashCode;
}
