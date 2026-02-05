# DNSTT Client

A cross-platform app that tunnels traffic through DNS, supporting two protocols:
- **DNSTT** - DNS-encoded tunnel using KCP + Noise encryption
- **Slipstream** - QUIC-over-DNS tunnel (~5x faster than DNSTT)

**Website**: [https://dnstt.xyz](https://dnstt.xyz)

## Features

- DNS tunneling for bypassing network restrictions
- Two tunnel protocols: DNSTT and Slipstream (QUIC-over-DNS)
- Simple one-tap connection
- Multiple DNS server support with latency testing
- Configuration management for both protocols
- Material Design UI
- **Android**: Full device VPN tunneling or local SOCKS5 proxy
- **Desktop** (macOS, Windows, Linux): SOCKS5 proxy mode

## How It Works

The app supports two DNS tunnel protocols:

### DNSTT
Data encoded in DNS TXT queries with KCP reliable transport and Noise encryption:
```
App Traffic → SOCKS5 → dnstt tunnel (KCP+Noise) → DNS queries → Server
```

### Slipstream
QUIC-over-DNS for higher throughput with TLS 1.3 encryption:
```
App Traffic → slipstream-client (QUIC) → DNS queries → Server
```

Both protocols use the same DNS server list — the selected DNS server carries tunnel traffic for DNSTT, or acts as the resolver for Slipstream.

## Download

Download the latest release from the [Releases](https://github.com/dnstt-xyz/dnstt_xyz_app/releases) page.

### Android

| File | Architecture | Devices |
|------|--------------|---------|
| `DNSTT-Client-*-Android-arm64-v8a.apk` | ARM 64-bit | Modern Android phones |
| `DNSTT-Client-*-Android-armeabi-v7a.apk` | ARM 32-bit | Older Android phones |
| `DNSTT-Client-*-Android-x86_64.apk` | x86_64 | Emulators, Chromebooks |

### Desktop

| File | Platform |
|------|----------|
| `DNSTT-Client-*-macOS-arm64.dmg` | macOS (Apple Silicon M1/M2/M3) |
| `DNSTT-Client-*-macOS-intel.dmg` | macOS (Intel) |
| `DNSTT-Client-*-Windows.zip` | Windows |
| `DNSTT-Client-*-Linux.tar.gz` | Linux |

## Usage

### Android
The app creates a system-wide VPN that tunnels all device traffic through DNS.

### Desktop
The app runs a local SOCKS5 proxy on `127.0.0.1:7000`. Configure your browser or applications to use this proxy.

**Firefox:**
1. Settings → Network Settings → Manual proxy configuration
2. SOCKS Host: `127.0.0.1`, Port: `7000`
3. Select SOCKS v5

**Chrome:**
```bash
google-chrome --proxy-server="socks5://127.0.0.1:7000"
```

## Building from Source

### Prerequisites

- Flutter SDK 3.x+
- Android SDK (API 21+) with NDK
- Go 1.21+
- gomobile: `go install golang.org/x/mobile/cmd/gomobile@latest`
- Java JDK 17
- Rust toolchain (for Slipstream): [https://rustup.rs](https://rustup.rs)
- cargo-ndk (for Android Slipstream): `cargo install cargo-ndk`

### Build Android

```bash
# Clone the repository (with submodules for Slipstream source)
git clone --recursive https://github.com/dnstt-xyz/dnstt_xyz_app.git
cd dnstt_xyz_app

# Install Flutter dependencies
flutter pub get

# Build split APKs (recommended)
flutter build apk --release --split-per-abi
```

### Build Desktop

```bash
# Build slipstream-client first (optional, for Slipstream protocol support)
git submodule update --init --recursive
./scripts/build_slipstream_desktop.sh

# macOS (bundles both DNSTT + Slipstream)
./scripts/build_macos.sh release

# Windows
./scripts/build_windows.sh release

# Linux
./scripts/build_linux.sh release
```

### Rebuilding the Go Library

The Go dnstt library source is included in `go_src/`. To rebuild:

```bash
# For Android
cd go_src
gomobile bind -v -androidapi 21 -target=android -o dnstt.aar ./mobile
cp dnstt.aar ../android/app/libs/

# For Desktop (macOS example)
CGO_ENABLED=1 go build -buildmode=c-shared -o libdnstt.dylib ./desktop
```

### Building Slipstream for Android

```bash
# Cross-compile for all Android architectures
./scripts/build_slipstream_android.sh
```

## Project Structure

```
dnstt_xyz_app/
├── android/          # Android native code (Kotlin)
├── go_src/           # Go dnstt library source
├── vendor/
│   └── slipstream-rust/  # Slipstream source (git submodule)
├── lib/              # Flutter/Dart code
│   ├── screens/      # UI screens
│   ├── providers/    # State management
│   ├── services/     # VPN, storage, and tunnel services
│   └── models/       # Data models
├── macos/            # macOS platform
├── windows/          # Windows platform
├── linux/            # Linux platform
└── scripts/          # Build scripts (DNSTT + Slipstream)
```

## Server Setup

You need a running tunnel server before using this app.

- **DNSTT server**: [dnstt-deploy](https://github.com/bugfloyd/dnstt-deploy) — automated deployment scripts for dnstt server
- **Slipstream server**: [slipstream-socks-deploy](https://github.com/dnstt-xyz/slipstream-socks-deploy) — automated deployment scripts for Slipstream server

## Configuration

The app requires:
- **DNSTT Config**: Tunnel domain and public key from your dnstt server
- **Slipstream Config**: Tunnel domain only (no public key needed, uses QUIC/TLS)
- **DNS Server**: A DNS resolver that can reach your tunnel server

## Support

If you find this project useful, consider supporting its development. Your support helps maintain servers and continue development.

- **USDT (Tron/TRC20)**: `TMBF7T8BpLhSkpauNUzcFHmHSEYL1Ucq5X`
- **USDT (Ethereum)**: `0xD2c70A2518E928cFeAF749Db39E67e073dB3E59a`
- **USDC (Ethereum)**: `0xD2c70A2518E928cFeAF749Db39E67e073dB3E59a`
- **Bitcoin**: `bc1q770vn8d65tq0jdh0zm4qkl7j47m6has0e2pkg6`
- **Solana**: `2hhrPoRocPHrWLYW7a7kENu3ZS2rXpBBCmaCfBsd9wdo`

## Links

- **Website**: [https://dnstt.xyz](https://dnstt.xyz)
- **GitHub**: [https://github.com/dnstt-xyz/dnstt_xyz_app](https://github.com/dnstt-xyz/dnstt_xyz_app)

## License

This project uses the dnstt protocol. See [go_src/COPYING](go_src/COPYING) for the dnstt license.
