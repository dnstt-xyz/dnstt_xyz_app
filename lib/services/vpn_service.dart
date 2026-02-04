import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'dnstt_ffi_service.dart';

enum VpnState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class VpnService {
  static const MethodChannel _channel = MethodChannel('xyz.dnstt.app/vpn');
  static const EventChannel _stateChannel = EventChannel('xyz.dnstt.app/vpn_state');

  static final VpnService _instance = VpnService._internal();
  factory VpnService() => _instance;
  VpnService._internal();

  final _stateController = StreamController<VpnState>.broadcast();
  Stream<VpnState> get stateStream => _stateController.stream;
  VpnState _currentState = VpnState.disconnected;
  VpnState get currentState => _currentState;

  bool _initialized = false;
  bool _platformSupported = true;
  bool _isDesktop = false;
  String? _lastError;

  // SSH process for desktop
  Process? _sshProcess;

  String? _connectedDns;
  String? _connectedDomain;

  // Proxy-only mode (Android)
  bool _isProxyMode = false;
  bool get isProxyMode => _isProxyMode;

  // Configurable proxy port
  int proxyPort = 1080;

  /// Check if we're on a desktop platform
  static bool get isDesktopPlatform =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Get the SOCKS proxy address when connected
  String get socksProxyAddress => '127.0.0.1:$proxyPort';

  /// Get the last error message
  String? get lastError => _lastError;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _isDesktop = isDesktopPlatform;

    if (_isDesktop) {
      // Initialize FFI for desktop
      try {
        DnsttFfiService.instance.load();
        _platformSupported = true;
      } catch (e) {
        print('Failed to load dnstt library: $e');
        _lastError = e.toString();
        _platformSupported = false;
      }
    } else {
      // Platform channels for mobile (iOS and Android)
      try {
        _stateChannel.receiveBroadcastStream().listen(
          (state) {
            _currentState = _parseState(state);
            _stateController.add(_currentState);
          },
          onError: (error) {
            // Platform channel not available
            _platformSupported = false;
          },
        );
      } catch (e) {
        _platformSupported = false;
      }
    }
  }

  // SSH tunnel mode (DNSTT + SSH dynamic port forwarding)
  bool _isSshTunnelMode = false;
  bool get isSshTunnelMode => _isSshTunnelMode;

  // Slipstream mode (QUIC-over-DNS tunnel)
  bool _isSlipstreamMode = false;
  bool get isSlipstreamMode => _isSlipstreamMode;

  VpnState _parseState(dynamic state) {
    switch (state) {
      case 'disconnected':
      case 'proxy_disconnected':
      case 'ssh_tunnel_disconnected':
      case 'slipstream_disconnected':
        _isProxyMode = false;
        _isSshTunnelMode = false;
        _isSlipstreamMode = false;
        return VpnState.disconnected;
      case 'connecting':
      case 'slipstream_connecting':
        return VpnState.connecting;
      case 'connected':
        return VpnState.connected;
      case 'proxy_connected':
        _isProxyMode = true;
        return VpnState.connected;
      case 'ssh_tunnel_connected':
        _isSshTunnelMode = true;
        return VpnState.connected;
      case 'slipstream_connected':
        _isSlipstreamMode = true;
        return VpnState.connected;
      case 'disconnecting':
      case 'slipstream_disconnecting':
        return VpnState.disconnecting;
      case 'error':
      case 'invalid':
      case 'proxy_error':
      case 'ssh_tunnel_error':
      case 'slipstream_error':
        return VpnState.error;
      default:
        return VpnState.disconnected;
    }
  }

  Future<bool> requestPermission() async {
    if (_isDesktop) {
      // No VPN permission needed on desktop - we just run a SOCKS proxy
      return true;
    }

    if (!_platformSupported) return true;

    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? true;
    } on MissingPluginException {
      _platformSupported = false;
      return true;
    } on PlatformException catch (e) {
      print('VPN permission error: ${e.message}');
      return false;
    }
  }

  Future<bool> connect({
    required String proxyHost,
    required int proxyPort,
    String? dnsServer,
    String? tunnelDomain,
    String? publicKey,
    bool sshMode = false,
  }) async {
    _currentState = VpnState.connecting;
    _stateController.add(_currentState);
    _lastError = null;
    // Reset all mode flags for regular VPN mode
    _isProxyMode = false;
    _isSshTunnelMode = sshMode;

    _connectedDns = dnsServer;
    _connectedDomain = tunnelDomain;

    if (_isDesktop) {
      return _connectDesktop(
        dnsServer: dnsServer ?? '8.8.8.8',
        tunnelDomain: tunnelDomain ?? '',
        publicKey: publicKey ?? '',
      );
    }

    if (!_platformSupported) {
      // Simulated connection for unsupported platforms
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    }

    try {
      final params = Platform.isIOS
          ? {
              'dnsServer': dnsServer ?? '8.8.8.8',
              'tunnelDomain': tunnelDomain ?? '',
              'publicKey': publicKey ?? '',
            }
          : {
              // Android parameters - now includes tunnel config for dnstt-client
              'proxyHost': proxyHost,
              'proxyPort': proxyPort,
              'dnsServer': dnsServer ?? '8.8.8.8',
              'tunnelDomain': tunnelDomain ?? '',
              'publicKey': publicKey ?? '',
              'sshMode': sshMode,
            };

      final result = await _channel.invokeMethod<bool>('connect', params);

      if (result == true) {
        _currentState = VpnState.connected;
      } else {
        _currentState = VpnState.error;
      }
      _stateController.add(_currentState);
      return result ?? false;
    } on MissingPluginException {
      // Fall back to simulated mode
      _platformSupported = false;
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    } on PlatformException catch (e) {
      print('VPN connect error: ${e.message}');
      _lastError = e.message;
      _currentState = VpnState.error;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Connect on desktop using FFI
  Future<bool> _connectDesktop({
    required String dnsServer,
    required String tunnelDomain,
    required String publicKey,
  }) async {
    // Ensure mode flags are reset for regular DNSTT mode
    _isProxyMode = false;
    _isSshTunnelMode = false;

    // Allow UI to update before blocking FFI calls
    await Future.delayed(const Duration(milliseconds: 50));

    try {
      final ffi = DnsttFfiService.instance;

      if (!ffi.isLoaded) {
        _lastError = 'FFI library not loaded';
        _currentState = VpnState.error;
        _stateController.add(_currentState);
        return false;
      }

      // Create the client
      final created = ffi.createClient(
        dnsServer: dnsServer,
        tunnelDomain: tunnelDomain,
        publicKey: publicKey,
        listenAddr: socksProxyAddress,
      );

      if (!created) {
        _lastError = ffi.getLastError();
        _currentState = VpnState.error;
        _stateController.add(_currentState);
        return false;
      }

      // Start the client
      final started = ffi.start();
      if (!started) {
        _lastError = ffi.getLastError();
        _currentState = VpnState.error;
        _stateController.add(_currentState);
        return false;
      }

      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    } catch (e) {
      _lastError = e.toString();
      _currentState = VpnState.error;
      _stateController.add(_currentState);
      return false;
    }
  }

  Future<bool> disconnect() async {
    _currentState = VpnState.disconnecting;
    _stateController.add(_currentState);

    if (_isDesktop) {
      return _disconnectDesktop();
    }

    if (!_platformSupported) {
      await Future.delayed(const Duration(milliseconds: 500));
      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _stateController.add(_currentState);
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('disconnect');
      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _stateController.add(_currentState);
      return result ?? true;
    } on MissingPluginException {
      _platformSupported = false;
      _currentState = VpnState.disconnected;
      _stateController.add(_currentState);
      return true;
    } on PlatformException catch (e) {
      print('VPN disconnect error: ${e.message}');
      _currentState = VpnState.error;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Disconnect on desktop using FFI
  Future<bool> _disconnectDesktop() async {
    try {
      final ffi = DnsttFfiService.instance;

      if (ffi.isLoaded) {
        ffi.stop();
      }

      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _stateController.add(_currentState);
      return true;
    } catch (e) {
      _lastError = e.toString();
      _currentState = VpnState.error;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Connect SSH tunnel on desktop using DNSTT FFI + system ssh command
  /// DNSTT creates TCP tunnel on internal port 7001, SSH creates SOCKS5 on configured proxy port
  Future<bool> _connectSshTunnelDesktop({
    required String dnsServer,
    required String tunnelDomain,
    required String publicKey,
    required String sshUsername,
    String? sshPassword,
  }) async {
    _currentState = VpnState.connecting;
    _stateController.add(_currentState);
    _lastError = null;
    // Reset all mode flags and set SSH tunnel mode
    _isProxyMode = false;
    _isSshTunnelMode = true;

    _connectedDns = dnsServer;
    _connectedDomain = tunnelDomain;

    try {
      // Step 1: Start DNSTT tunnel on internal port 7001 (forwards to SSH server)
      final ffi = DnsttFfiService.instance;

      if (!ffi.isLoaded) {
        _lastError = 'FFI library not loaded';
        _currentState = VpnState.error;
        _stateController.add(_currentState);
        return false;
      }

      // Stop any existing client first
      if (ffi.isRunning) {
        ffi.stop();
      }

      // Create the DNSTT client on internal port
      final created = ffi.createClient(
        dnsServer: dnsServer,
        tunnelDomain: tunnelDomain,
        publicKey: publicKey,
        listenAddr: '127.0.0.1:7001',
      );

      if (!created) {
        _lastError = ffi.getLastError();
        _currentState = VpnState.error;
        _stateController.add(_currentState);
        return false;
      }

      // Start the DNSTT tunnel
      final started = ffi.start();
      if (!started) {
        _lastError = ffi.getLastError();
        _currentState = VpnState.error;
        _stateController.add(_currentState);
        return false;
      }

      // Give DNSTT a moment to establish the tunnel
      await Future.delayed(const Duration(seconds: 2));

      // Step 2: Start SSH with dynamic port forwarding on configured proxy port
      final bindAddress = '$proxyPort';

      // DNSTT creates a SOCKS5 proxy on port 7001, so SSH must use ProxyCommand
      // to connect through the SOCKS5 proxy to the SSH server (via tunnel)
      // The SSH server address should be the actual server hostname/IP that the DNSTT server forwards to
      // Since DNSTT tunnel forwards to the same server running SSH, we connect to localhost:22 through the proxy
      final proxyCommand = 'nc -X 5 -x 127.0.0.1:7001 %h %p';
      print('Starting SSH tunnel: ssh -D $bindAddress -o ProxyCommand="$proxyCommand" $sshUsername@localhost');

      if (sshPassword != null && sshPassword.isNotEmpty) {
        // Try using sshpass if available
        final sshpassCheck = await Process.run('which', ['sshpass']);
        if (sshpassCheck.exitCode == 0) {
          _sshProcess = await Process.start('sshpass', [
            '-p', sshPassword,
            'ssh',
            '-D', bindAddress,
            '-o', 'ProxyCommand=$proxyCommand',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'ServerAliveInterval=15',
            '-o', 'ServerAliveCountMax=3',
            '-N',
            '$sshUsername@localhost',
          ]);
        } else {
          // No sshpass, use expect-style approach with stdin
          _sshProcess = await Process.start('ssh', [
            '-D', bindAddress,
            '-o', 'ProxyCommand=$proxyCommand',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'ServerAliveInterval=15',
            '-o', 'ServerAliveCountMax=3',
            '-o', 'PreferredAuthentications=password',
            '-o', 'PubkeyAuthentication=no',
            '-N',
            '$sshUsername@localhost',
          ]);

          // Listen for password prompt and send password
          _sshProcess!.stdout.listen((data) {
            print('SSH stdout: ${String.fromCharCodes(data)}');
          });

          _sshProcess!.stderr.listen((data) {
            final output = String.fromCharCodes(data);
            print('SSH stderr: $output');
            if (output.toLowerCase().contains('password')) {
              _sshProcess!.stdin.writeln(sshPassword);
            }
          });
        }
      } else {
        // No password, try key-based auth
        _sshProcess = await Process.start('ssh', [
          '-D', bindAddress,
          '-o', 'ProxyCommand=$proxyCommand',
          '-o', 'StrictHostKeyChecking=no',
          '-o', 'UserKnownHostsFile=/dev/null',
          '-o', 'ServerAliveInterval=15',
          '-o', 'ServerAliveCountMax=3',
          '-N',
          '$sshUsername@localhost',
        ]);
      }

      // Monitor SSH process
      _sshProcess!.exitCode.then((code) {
        print('SSH process exited with code: $code');
        if (_isSshTunnelMode && _currentState == VpnState.connected) {
          _lastError = 'SSH tunnel disconnected (exit code: $code)';
          _currentState = VpnState.error;
          _isSshTunnelMode = false;
          _stateController.add(_currentState);
          try { ffi.stop(); } catch (_) {}
        }
      });

      // Wait a moment and check if SSH is still running
      await Future.delayed(const Duration(seconds: 3));

      // Check if process is still running
      final exitCodeFuture = _sshProcess!.exitCode;
      final result = await Future.any([
        exitCodeFuture.then((code) => 'exited:$code'),
        Future.delayed(const Duration(milliseconds: 500), () => 'running'),
      ]);

      if (result.startsWith('exited')) {
        final code = result.split(':')[1];
        _lastError = 'SSH failed to connect (exit code: $code)';
        _currentState = VpnState.error;
        _isSshTunnelMode = false;
        _stateController.add(_currentState);
        ffi.stop();
        return false;
      }

      print('SSH tunnel established on port $proxyPort');
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    } catch (e) {
      _lastError = e.toString();
      _currentState = VpnState.error;
      _isSshTunnelMode = false;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Disconnect SSH tunnel on desktop
  Future<bool> _disconnectSshTunnelDesktop() async {
    try {
      // Kill SSH process
      if (_sshProcess != null) {
        _sshProcess!.kill();
        _sshProcess = null;
      }

      // Stop DNSTT
      final ffi = DnsttFfiService.instance;
      if (ffi.isLoaded) {
        ffi.stop();
      }

      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _isSshTunnelMode = false;
      _stateController.add(_currentState);
      return true;
    } catch (e) {
      _lastError = e.toString();
      _currentState = VpnState.error;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Connect in proxy-only mode on Android (no VPN, just SOCKS5 proxy)
  Future<bool> connectProxy({
    String? dnsServer,
    String? tunnelDomain,
    String? publicKey,
    int proxyPort = 1080,
  }) async {
    if (_isDesktop) {
      // Desktop always uses proxy mode
      return connect(
        proxyHost: '127.0.0.1',
        proxyPort: proxyPort,
        dnsServer: dnsServer,
        tunnelDomain: tunnelDomain,
        publicKey: publicKey,
      );
    }

    _currentState = VpnState.connecting;
    _stateController.add(_currentState);
    _lastError = null;
    // Reset all mode flags and set proxy mode
    _isSshTunnelMode = false;
    _isProxyMode = true;

    _connectedDns = dnsServer;
    _connectedDomain = tunnelDomain;

    if (!_platformSupported) {
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('connectProxy', {
        'dnsServer': dnsServer ?? '8.8.8.8',
        'tunnelDomain': tunnelDomain ?? '',
        'publicKey': publicKey ?? '',
        'proxyPort': proxyPort,
      });

      if (result == true) {
        _currentState = VpnState.connected;
      } else {
        _currentState = VpnState.error;
        _isProxyMode = false;
      }
      _stateController.add(_currentState);
      return result ?? false;
    } on MissingPluginException {
      _platformSupported = false;
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    } on PlatformException catch (e) {
      print('Proxy connect error: ${e.message}');
      _lastError = e.message;
      _currentState = VpnState.error;
      _isProxyMode = false;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Disconnect proxy-only mode on Android
  Future<bool> disconnectProxy() async {
    if (_isDesktop) {
      return disconnect();
    }

    _currentState = VpnState.disconnecting;
    _stateController.add(_currentState);

    if (!_platformSupported) {
      await Future.delayed(const Duration(milliseconds: 500));
      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _isProxyMode = false;
      _stateController.add(_currentState);
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('disconnectProxy');
      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _isProxyMode = false;
      _stateController.add(_currentState);
      return result ?? true;
    } on MissingPluginException {
      _platformSupported = false;
      _currentState = VpnState.disconnected;
      _isProxyMode = false;
      _stateController.add(_currentState);
      return true;
    } on PlatformException catch (e) {
      print('Proxy disconnect error: ${e.message}');
      _currentState = VpnState.error;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Check if proxy is running (Android only)
  Future<bool> isProxyConnected() async {
    if (_isDesktop) {
      return isConnected();
    }

    if (!_platformSupported) {
      return _currentState == VpnState.connected && _isProxyMode;
    }

    try {
      final result = await _channel.invokeMethod<bool>('isProxyConnected');
      return result ?? false;
    } on MissingPluginException {
      return _currentState == VpnState.connected && _isProxyMode;
    } on PlatformException {
      return false;
    }
  }

  /// Connect SSH tunnel over DNSTT
  /// Flow: DNSTT tunnel -> SSH client -> SSH dynamic port forwarding -> local SOCKS5 proxy on configured port
  Future<bool> connectSshTunnel({
    String? dnsServer,
    String? tunnelDomain,
    String? publicKey,
    required String sshUsername,
    String? sshPassword,
    String? sshPrivateKey,
  }) async {
    if (_isDesktop) {
      return _connectSshTunnelDesktop(
        dnsServer: dnsServer ?? '8.8.8.8',
        tunnelDomain: tunnelDomain ?? '',
        publicKey: publicKey ?? '',
        sshUsername: sshUsername,
        sshPassword: sshPassword,
      );
    }

    _currentState = VpnState.connecting;
    _stateController.add(_currentState);
    _lastError = null;
    // Reset all mode flags and set SSH tunnel mode
    _isProxyMode = false;
    _isSshTunnelMode = true;

    _connectedDns = dnsServer;
    _connectedDomain = tunnelDomain;

    if (!_platformSupported) {
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('connectSshTunnel', {
        'dnsServer': dnsServer ?? '8.8.8.8',
        'tunnelDomain': tunnelDomain ?? '',
        'publicKey': publicKey ?? '',
        'sshUsername': sshUsername,
        'sshPassword': sshPassword,
        'sshPrivateKey': sshPrivateKey,
      });

      if (result == true) {
        _currentState = VpnState.connected;
      } else {
        _currentState = VpnState.error;
        _isSshTunnelMode = false;
      }
      _stateController.add(_currentState);
      return result ?? false;
    } on MissingPluginException {
      _platformSupported = false;
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    } on PlatformException catch (e) {
      print('SSH tunnel connect error: ${e.message}');
      _lastError = e.message;
      _currentState = VpnState.error;
      _isSshTunnelMode = false;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Connect SSH tunnel with VPN mode (routes all device traffic through SSH tunnel)
  /// Android only - on desktop, use connectSshTunnel instead
  Future<bool> connectSshTunnelVpn({
    String? dnsServer,
    String? tunnelDomain,
    String? publicKey,
    required String sshUsername,
    String? sshPassword,
    String? sshPrivateKey,
  }) async {
    if (_isDesktop) {
      // Desktop doesn't have VPN mode, use regular SSH tunnel
      return connectSshTunnel(
        dnsServer: dnsServer,
        tunnelDomain: tunnelDomain,
        publicKey: publicKey,
        sshUsername: sshUsername,
        sshPassword: sshPassword,
        sshPrivateKey: sshPrivateKey,
      );
    }

    _currentState = VpnState.connecting;
    _stateController.add(_currentState);
    _lastError = null;
    // Reset all mode flags and set SSH tunnel mode
    _isProxyMode = false;
    _isSshTunnelMode = true;

    _connectedDns = dnsServer;
    _connectedDomain = tunnelDomain;

    if (!_platformSupported) {
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('connectSshTunnelVpn', {
        'dnsServer': dnsServer ?? '8.8.8.8',
        'tunnelDomain': tunnelDomain ?? '',
        'publicKey': publicKey ?? '',
        'sshUsername': sshUsername,
        'sshPassword': sshPassword,
        'sshPrivateKey': sshPrivateKey,
      });

      if (result == true) {
        _currentState = VpnState.connected;
      } else {
        _currentState = VpnState.error;
        _isSshTunnelMode = false;
      }
      _stateController.add(_currentState);
      return result ?? false;
    } on MissingPluginException {
      _platformSupported = false;
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    } on PlatformException catch (e) {
      print('SSH tunnel VPN connect error: ${e.message}');
      _lastError = e.message;
      _currentState = VpnState.error;
      _isSshTunnelMode = false;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Disconnect SSH tunnel
  Future<bool> disconnectSshTunnel() async {
    if (_isDesktop) {
      return _disconnectSshTunnelDesktop();
    }

    _currentState = VpnState.disconnecting;
    _stateController.add(_currentState);

    if (!_platformSupported) {
      await Future.delayed(const Duration(milliseconds: 500));
      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _isSshTunnelMode = false;
      _stateController.add(_currentState);
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('disconnectSshTunnel');
      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _isSshTunnelMode = false;
      _stateController.add(_currentState);
      return result ?? true;
    } on MissingPluginException {
      _platformSupported = false;
      _currentState = VpnState.disconnected;
      _isSshTunnelMode = false;
      _stateController.add(_currentState);
      return true;
    } on PlatformException catch (e) {
      print('SSH tunnel disconnect error: ${e.message}');
      _currentState = VpnState.error;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Check if SSH tunnel is running
  Future<bool> isSshTunnelConnected() async {
    if (_isDesktop) {
      return _currentState == VpnState.connected && _isSshTunnelMode && _sshProcess != null;
    }

    if (!_platformSupported) {
      return _currentState == VpnState.connected && _isSshTunnelMode;
    }

    try {
      final result = await _channel.invokeMethod<bool>('isSshTunnelConnected');
      return result ?? false;
    } on MissingPluginException {
      return _currentState == VpnState.connected && _isSshTunnelMode;
    } on PlatformException {
      return false;
    }
  }

  /// Connect using Slipstream (QUIC-over-DNS tunnel)
  /// Android only - provides a TCP proxy on the specified port
  Future<bool> connectSlipstream({
    String? dnsServer,
    String? tunnelDomain,
    int proxyPort = 7000,
    bool authoritative = false,
  }) async {
    if (_isDesktop) {
      // Slipstream not yet supported on desktop
      _lastError = 'Slipstream is only supported on Android';
      return false;
    }

    _currentState = VpnState.connecting;
    _stateController.add(_currentState);
    _lastError = null;
    // Reset all mode flags and set slipstream mode
    _isProxyMode = false;
    _isSshTunnelMode = false;
    _isSlipstreamMode = true;

    _connectedDns = dnsServer;
    _connectedDomain = tunnelDomain;

    if (!_platformSupported) {
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('connectSlipstream', {
        'dnsServer': dnsServer ?? '8.8.8.8',
        'tunnelDomain': tunnelDomain ?? '',
        'proxyPort': proxyPort,
        'authoritative': authoritative,
      });

      if (result == true) {
        _currentState = VpnState.connected;
      } else {
        _currentState = VpnState.error;
        _isSlipstreamMode = false;
      }
      _stateController.add(_currentState);
      return result ?? false;
    } on MissingPluginException {
      _platformSupported = false;
      await Future.delayed(const Duration(milliseconds: 1500));
      _currentState = VpnState.connected;
      _stateController.add(_currentState);
      return true;
    } on PlatformException catch (e) {
      print('Slipstream connect error: ${e.message}');
      _lastError = e.message;
      _currentState = VpnState.error;
      _isSlipstreamMode = false;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Disconnect Slipstream tunnel
  Future<bool> disconnectSlipstream() async {
    if (_isDesktop) {
      return true; // No-op on desktop
    }

    _currentState = VpnState.disconnecting;
    _stateController.add(_currentState);

    if (!_platformSupported) {
      await Future.delayed(const Duration(milliseconds: 500));
      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _isSlipstreamMode = false;
      _stateController.add(_currentState);
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('disconnectSlipstream');
      _currentState = VpnState.disconnected;
      _connectedDns = null;
      _connectedDomain = null;
      _isSlipstreamMode = false;
      _stateController.add(_currentState);
      return result ?? true;
    } on MissingPluginException {
      _platformSupported = false;
      _currentState = VpnState.disconnected;
      _isSlipstreamMode = false;
      _stateController.add(_currentState);
      return true;
    } on PlatformException catch (e) {
      print('Slipstream disconnect error: ${e.message}');
      _currentState = VpnState.error;
      _stateController.add(_currentState);
      return false;
    }
  }

  /// Check if Slipstream is running
  Future<bool> isSlipstreamConnected() async {
    if (_isDesktop) {
      return false; // Not supported on desktop
    }

    if (!_platformSupported) {
      return _currentState == VpnState.connected && _isSlipstreamMode;
    }

    try {
      final result = await _channel.invokeMethod<bool>('isSlipstreamConnected');
      return result ?? false;
    } on MissingPluginException {
      return _currentState == VpnState.connected && _isSlipstreamMode;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> isConnected() async {
    if (_isDesktop) {
      try {
        final ffi = DnsttFfiService.instance;
        return ffi.isLoaded && ffi.isRunning;
      } catch (e) {
        return false;
      }
    }

    if (!_platformSupported) {
      return _currentState == VpnState.connected;
    }

    try {
      final result = await _channel.invokeMethod<bool>('isConnected');
      return result ?? false;
    } on MissingPluginException {
      _platformSupported = false;
      return _currentState == VpnState.connected;
    } on PlatformException {
      return false;
    }
  }

  String? get connectedDns => _connectedDns;
  String? get connectedDomain => _connectedDomain;

  /// Test a DNS server by making an actual connection through the tunnel
  /// Returns latency in milliseconds on success, -1 on failure, -2 on cancelled
  Future<int> testDnsServer({
    required String dnsServer,
    required String tunnelDomain,
    required String publicKey,
    String testUrl = 'https://api.ipify.org?format=json',
    int timeoutMs = 15000,
  }) async {
    if (_isDesktop) {
      // Use FFI on desktop
      try {
        final ffi = DnsttFfiService.instance;
        if (!ffi.isLoaded) {
          ffi.load();
        }
        return ffi.testDnsServer(
          dnsServer: dnsServer,
          tunnelDomain: tunnelDomain,
          publicKey: publicKey,
          testUrl: testUrl,
          timeoutMs: timeoutMs,
        );
      } catch (e) {
        print('FFI test error: $e');
        return -1;
      }
    }

    // Use method channel on mobile
    if (!_platformSupported) {
      return -1;
    }

    try {
      final result = await _channel.invokeMethod<int>('testDnsServer', {
        'dnsServer': dnsServer,
        'tunnelDomain': tunnelDomain,
        'publicKey': publicKey,
        'testUrl': testUrl,
        'timeoutMs': timeoutMs,
      });
      return result ?? -1;
    } on MissingPluginException {
      return -1;
    } on PlatformException catch (e) {
      print('Test DNS server error: ${e.message}');
      return -1;
    }
  }

  /// Cancel all running DNS tests (Android only)
  Future<void> cancelAllTests() async {
    if (_isDesktop) {
      // Desktop cancellation handled via app_state
      return;
    }

    if (!_platformSupported) return;

    try {
      await _channel.invokeMethod('cancelAllTests');
    } on MissingPluginException {
      // Ignore
    } on PlatformException catch (e) {
      print('Cancel tests error: ${e.message}');
    }
  }

  /// Reset test cancellation state (Android only)
  /// Call this before starting a new batch of tests
  Future<void> resetTestCancellation() async {
    if (_isDesktop) {
      return;
    }

    if (!_platformSupported) return;

    try {
      await _channel.invokeMethod('resetTestCancellation');
    } on MissingPluginException {
      // Ignore
    } on PlatformException catch (e) {
      print('Reset test cancellation error: ${e.message}');
    }
  }

  void dispose() {
    if (_isDesktop) {
      try {
        if (_sshProcess != null) {
          _sshProcess!.kill();
          _sshProcess = null;
        }
        DnsttFfiService.instance.stop();
      } catch (_) {}
    }
    _stateController.close();
  }
}
