import 'package:uuid/uuid.dart';

/// Tunnel type enumeration
/// - socks5: Server configured to forward to SOCKS5 proxy (standard DNSTT)
/// - ssh: Server configured to forward to SSH server (port 22)
///
/// For SSH mode:
/// 1. DNSTT creates TCP tunnel to SSH server (127.0.0.1:1080 -> SSH)
/// 2. App's SSH client connects through tunnel using credentials from config
/// 3. SSH dynamic port forwarding creates local SOCKS5 proxy
/// 4. User apps connect to the local SOCKS5 proxy
enum TunnelType {
  socks5,
  ssh,
}

class DnsttConfig {
  final String id;
  String name;
  String publicKey;
  String tunnelDomain;

  /// Tunnel type - indicates what the server is configured for
  TunnelType tunnelType;

  /// SSH settings (only used when tunnelType is ssh)
  /// The SSH server is accessed through the DNSTT tunnel
  String? sshUsername;
  String? sshPassword;
  String? sshPrivateKey;

  DnsttConfig({
    String? id,
    required this.name,
    required this.publicKey,
    required this.tunnelDomain,
    this.tunnelType = TunnelType.socks5,
    this.sshUsername,
    this.sshPassword,
    this.sshPrivateKey,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'publicKey': publicKey,
        'tunnelDomain': tunnelDomain,
        'tunnelType': tunnelType.name,
        'sshUsername': sshUsername,
        'sshPassword': sshPassword,
        'sshPrivateKey': sshPrivateKey,
      };

  factory DnsttConfig.fromJson(Map<String, dynamic> json) => DnsttConfig(
        id: json['id'],
        name: json['name'],
        publicKey: json['publicKey'],
        tunnelDomain: json['tunnelDomain'],
        tunnelType: _parseTunnelType(json['tunnelType']),
        sshUsername: json['sshUsername'],
        sshPassword: json['sshPassword'],
        sshPrivateKey: json['sshPrivateKey'],
      );

  static TunnelType _parseTunnelType(dynamic value) {
    if (value == null) return TunnelType.socks5;
    if (value is String) {
      switch (value.toLowerCase()) {
        case 'ssh':
          return TunnelType.ssh;
        case 'socks5':
        default:
          return TunnelType.socks5;
      }
    }
    return TunnelType.socks5;
  }

  bool get isValid =>
      publicKey.isNotEmpty &&
      tunnelDomain.isNotEmpty &&
      publicKey.length == 64;

  /// Check if SSH settings are valid (when tunnel type is ssh)
  bool get isSshValid =>
      tunnelType != TunnelType.ssh ||
      (sshUsername != null &&
          sshUsername!.isNotEmpty &&
          (sshPassword != null && sshPassword!.isNotEmpty ||
              sshPrivateKey != null && sshPrivateKey!.isNotEmpty));

  /// Full validation including SSH settings
  bool get isFullyValid => isValid && isSshValid;

  /// Copy with method for easy modification
  DnsttConfig copyWith({
    String? id,
    String? name,
    String? publicKey,
    String? tunnelDomain,
    TunnelType? tunnelType,
    String? sshUsername,
    String? sshPassword,
    String? sshPrivateKey,
  }) {
    return DnsttConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      publicKey: publicKey ?? this.publicKey,
      tunnelDomain: tunnelDomain ?? this.tunnelDomain,
      tunnelType: tunnelType ?? this.tunnelType,
      sshUsername: sshUsername ?? this.sshUsername,
      sshPassword: sshPassword ?? this.sshPassword,
      sshPrivateKey: sshPrivateKey ?? this.sshPrivateKey,
    );
  }
}
