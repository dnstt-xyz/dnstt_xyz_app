import 'package:uuid/uuid.dart';

/// Transport type enumeration - the underlying tunnel protocol
/// - dnstt: Original DNSTT protocol (DNS TXT + KCP + Noise)
/// - slipstream: Slipstream protocol (QUIC-over-DNS, ~5x faster)
enum TransportType {
  dnstt,
  slipstream,
}

/// Tunnel type enumeration - what the server forwards to
/// - socks5: Server configured to forward to SOCKS5 proxy (standard DNSTT)
/// - ssh: Server configured to forward to SSH server (port 22)
///
/// For SSH mode:
/// 1. DNSTT creates TCP tunnel to SSH server (127.0.0.1:<port> -> SSH)
/// 2. App's SSH client connects through tunnel using credentials from config
/// 3. SSH dynamic port forwarding creates local SOCKS5 proxy
/// 4. User apps connect to the local SOCKS5 proxy (port configurable in settings)
enum TunnelType {
  socks5,
  ssh,
}

class DnsttConfig {
  final String id;
  String name;
  String publicKey;
  String tunnelDomain;

  /// Transport type - the underlying tunnel protocol
  TransportType transportType;

  /// Tunnel type - indicates what the server is configured for
  TunnelType tunnelType;

  /// SSH settings (only used when tunnelType is ssh)
  /// The SSH server is accessed through the DNSTT tunnel
  String? sshUsername;
  String? sshPassword;
  String? sshPrivateKey;

  /// Slipstream-specific settings (only used when transportType is slipstream)
  /// Congestion control algorithm: "bbr" or "dcubic" (default: "dcubic")
  String? congestionControl;
  /// Keep-alive interval in milliseconds (default: 400)
  int? keepAliveInterval;
  /// Generic Segmentation Offload (default: false)
  bool? gsoEnabled;

  DnsttConfig({
    String? id,
    required this.name,
    required this.publicKey,
    required this.tunnelDomain,
    this.transportType = TransportType.dnstt,
    this.tunnelType = TunnelType.socks5,
    this.sshUsername,
    this.sshPassword,
    this.sshPrivateKey,
    this.congestionControl,
    this.keepAliveInterval,
    this.gsoEnabled,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'publicKey': publicKey,
        'tunnelDomain': tunnelDomain,
        'transportType': transportType.name,
        'tunnelType': tunnelType.name,
        'sshUsername': sshUsername,
        'sshPassword': sshPassword,
        'sshPrivateKey': sshPrivateKey,
        'congestionControl': congestionControl,
        'keepAliveInterval': keepAliveInterval,
        'gsoEnabled': gsoEnabled,
      };

  factory DnsttConfig.fromJson(Map<String, dynamic> json) => DnsttConfig(
        id: json['id'],
        name: json['name'],
        publicKey: json['publicKey'] ?? '',
        tunnelDomain: json['tunnelDomain'],
        transportType: _parseTransportType(json['transportType']),
        tunnelType: _parseTunnelType(json['tunnelType']),
        sshUsername: json['sshUsername'],
        sshPassword: json['sshPassword'],
        sshPrivateKey: json['sshPrivateKey'],
        congestionControl: json['congestionControl'],
        keepAliveInterval: json['keepAliveInterval'],
        gsoEnabled: json['gsoEnabled'],
      );

  static TransportType _parseTransportType(dynamic value) {
    if (value == null) return TransportType.dnstt;
    if (value is String) {
      switch (value.toLowerCase()) {
        case 'slipstream':
          return TransportType.slipstream;
        case 'dnstt':
        default:
          return TransportType.dnstt;
      }
    }
    return TransportType.dnstt;
  }

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

  /// Whether this config uses the Slipstream transport
  bool get isSlipstream => transportType == TransportType.slipstream;

  /// Basic validation
  /// Slipstream configs don't need publicKey, but DNSTT configs do
  bool get isValid {
    if (tunnelDomain.isEmpty) return false;
    if (isSlipstream) return true;
    return publicKey.isNotEmpty && publicKey.length == 64;
  }

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
    TransportType? transportType,
    TunnelType? tunnelType,
    String? sshUsername,
    String? sshPassword,
    String? sshPrivateKey,
    String? congestionControl,
    int? keepAliveInterval,
    bool? gsoEnabled,
  }) {
    return DnsttConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      publicKey: publicKey ?? this.publicKey,
      tunnelDomain: tunnelDomain ?? this.tunnelDomain,
      transportType: transportType ?? this.transportType,
      tunnelType: tunnelType ?? this.tunnelType,
      sshUsername: sshUsername ?? this.sshUsername,
      sshPassword: sshPassword ?? this.sshPassword,
      sshPrivateKey: sshPrivateKey ?? this.sshPrivateKey,
      congestionControl: congestionControl ?? this.congestionControl,
      keepAliveInterval: keepAliveInterval ?? this.keepAliveInterval,
      gsoEnabled: gsoEnabled ?? this.gsoEnabled,
    );
  }
}
