# SSH Tunnel over DNSTT Architecture

This document describes how the SSH tunnel mode works in the DNSTT app.

## Overview

The SSH tunnel mode provides an alternative to the standard SOCKS5 proxy mode. Instead of DNSTT directly providing a SOCKS5 proxy, the app establishes an SSH connection through the DNSTT tunnel and uses SSH dynamic port forwarding to create a SOCKS5 proxy.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Android Phone                       │
│                                                                 │
│  User Apps ──► SOCKS5 Proxy (127.0.0.1:1080)                   │
│                      │                                          │
│                      ▼                                          │
│              SSH Client (JSch in app)                           │
│              Uses: sshUsername, sshPassword                     │
│                      │                                          │
│                      ▼                                          │
│              DNSTT Client (127.0.0.1:7000)                      │
│              Uses: publicKey, tunnelDomain                      │
│                      │                                          │
└──────────────────────┼──────────────────────────────────────────┘
                       │ DNS queries
                       ▼
              ┌─────────────────┐
              │   DNS Resolver   │
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │  DNSTT Server   │
              │  (your server)  │
              │       │         │
              │       ▼         │
              │  SSH Server:22  │
              └────────┬────────┘
                       │
                       ▼
                   Internet
```

## Data Flow

1. **User Apps** connect to the local SOCKS5 proxy at `127.0.0.1:1080`
2. **SSH Client (JSch)** receives SOCKS5 requests and forwards them through SSH dynamic port forwarding
3. **DNSTT Client** tunnels the SSH traffic over DNS queries to the tunnel domain
4. **DNS Resolver** forwards queries to the authoritative DNS server
5. **DNSTT Server** decodes DNS traffic and forwards to the local SSH server
6. **SSH Server** authenticates the connection and forwards traffic to the internet

## Configuration

A single config contains both DNSTT and SSH settings:

| Field | Description |
|-------|-------------|
| `publicKey` | DNSTT server's 64-character hex public key |
| `tunnelDomain` | DNSTT tunnel domain (e.g., `t.example.com`) |
| `tunnelType` | Set to `ssh` for SSH tunnel mode |
| `sshUsername` | SSH username for authentication |
| `sshPassword` | SSH password (optional if using key) |
| `sshPrivateKey` | SSH private key in OpenSSH format (optional) |
| `sshLocalPort` | Local SOCKS5 proxy port (default: 1080) |

## Advantages of SSH Tunnel Mode

- **Authentication**: SSH provides user authentication, adding a layer of access control
- **Encryption**: SSH provides end-to-end encryption between the app and SSH server
- **Flexibility**: Can use password or key-based authentication
- **Compatibility**: Works with existing SSH infrastructure

## Implementation Details

- **Android**: Uses [JSch](https://github.com/mwiede/jsch) library for SSH client functionality
- **DNSTT**: Creates TCP tunnel on `127.0.0.1:7000` that forwards to SSH server port 22
- **SSH**: Connects through the DNSTT tunnel and implements dynamic port forwarding (equivalent to `ssh -D`)
