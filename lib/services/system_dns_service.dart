import 'dart:io';
import 'package:flutter/services.dart';

class SystemDnsService {
  static const _channel = MethodChannel('xyz.dnstt.app/vpn');

  static Future<String?> detectSystemDns() async {
    try {
      if (Platform.isAndroid) {
        return await _detectAndroid();
      } else if (Platform.isMacOS) {
        return await _detectMacOS();
      } else if (Platform.isWindows) {
        return await _detectWindows();
      } else if (Platform.isLinux) {
        return await _detectLinux();
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _detectAndroid() async {
    try {
      final dns = await _channel.invokeMethod<String>('getSystemDns');
      return (dns != null && _isValidIp(dns)) ? dns : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _detectMacOS() async {
    final result = await Process.run('scutil', ['--dns']);
    if (result.exitCode != 0) return null;

    final lines = (result.stdout as String).split('\n');
    for (final line in lines) {
      final match = RegExp(r'nameserver\[\d+\]\s*:\s*(\S+)').firstMatch(line);
      if (match != null) {
        final ip = match.group(1)!;
        if (_isValidIp(ip)) return ip;
      }
    }
    return null;
  }

  static Future<String?> _detectWindows() async {
    // Try PowerShell first
    try {
      final result = await Process.run('powershell', [
        '-Command',
        'Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses | Select-Object -First 1',
      ]);
      if (result.exitCode == 0) {
        final ip = (result.stdout as String).trim();
        if (_isValidIp(ip)) return ip;
      }
    } catch (_) {}

    // Fallback to ipconfig
    try {
      final result = await Process.run('ipconfig', ['/all']);
      if (result.exitCode == 0) {
        final lines = (result.stdout as String).split('\n');
        for (final line in lines) {
          if (line.contains('DNS Servers') || line.contains('DNS-Server')) {
            final match = RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})').firstMatch(line);
            if (match != null) {
              final ip = match.group(1)!;
              if (_isValidIp(ip)) return ip;
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  static Future<String?> _detectLinux() async {
    // Try resolvectl first
    try {
      final result = await Process.run('resolvectl', ['status']);
      if (result.exitCode == 0) {
        final lines = (result.stdout as String).split('\n');
        bool inDnsSection = false;
        for (final line in lines) {
          if (line.contains('DNS Servers:')) {
            inDnsSection = true;
            final match = RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})').firstMatch(line);
            if (match != null) {
              final ip = match.group(1)!;
              if (_isValidIp(ip) && ip != '127.0.0.53') return ip;
            }
            continue;
          }
          if (inDnsSection) {
            final match = RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})').firstMatch(line.trim());
            if (match != null) {
              final ip = match.group(1)!;
              if (_isValidIp(ip) && ip != '127.0.0.53') return ip;
            } else {
              inDnsSection = false;
            }
          }
        }
      }
    } catch (_) {}

    // Fallback to /etc/resolv.conf
    try {
      final file = File('/etc/resolv.conf');
      if (await file.exists()) {
        final lines = await file.readAsLines();
        for (final line in lines) {
          if (line.startsWith('nameserver')) {
            final match = RegExp(r'nameserver\s+(\S+)').firstMatch(line);
            if (match != null) {
              final ip = match.group(1)!;
              if (_isValidIp(ip) && ip != '127.0.0.53') return ip;
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  static bool _isValidIp(String ip) {
    return RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').hasMatch(ip);
  }
}
