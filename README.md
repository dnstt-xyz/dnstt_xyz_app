# DNSTT Client

A cross-platform app that tunnels traffic through DNS using the [dnstt protocol](https://www.bamsoftware.com/software/dnstt/).

**Website**: [https://dnstt.xyz](https://dnstt.xyz)

## Features

- DNS tunneling for bypassing network restrictions
- Simple one-tap connection
- Multiple DNS server support
- DNSTT configuration management
- **Slipstream support**: Alternative QUIC-over-DNS tunnel (Android)
- Material Design UI
- **Android**: Full device VPN tunneling or proxy mode
- **Desktop** (macOS, Windows, Linux): SOCKS5 proxy mode

## How It Works

DNSTT tunnels data through DNS queries using the following protocol stack:

```
App Traffic → TUN Interface → TCP State Machine → SOCKS5 → dnstt tunnel → DNS queries → Server
```

1. **DNS Transport** - Data encoded in DNS TXT queries/responses
2. **KCP** - Reliable transport over UDP (DNS)
3. **Noise** - Encryption using Noise_NK protocol
4. **smux** - Multiplexed streams over the encrypted channel
5. **SOCKS5** - Local proxy interface

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

### Build Android

```bash
# Clone the repository
git clone https://github.com/dnstt-xyz/dnstt_xyz_app.git
cd dnstt_xyz_app

# Install Flutter dependencies
flutter pub get

# Build split APKs (recommended)
flutter build apk --release --split-per-abi
```

### Building Slipstream (Optional)

Slipstream provides an alternative QUIC-over-DNS tunnel. To build with Slipstream support:

```bash
# Initialize submodule
git submodule update --init --recursive

# Apply the cross-compilation patch
cd slipstream-plugin-android/app/src/main/rust/slipstream-rust
git apply ../../../../../picoquic.crosscompile.diff

# Build slipstream (requires Rust and Android NDK)
cd ../../../..  # back to slipstream-plugin-android/app
./gradlew assembleDebug

# Copy binaries to dnstt_xyz_app
cp -r build/rustJniLibs/android/* ../../android/app/src/main/jniLibs/
```

### Build Desktop

```bash
# macOS
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

## Project Structure

```
dnstt_xyz_app/
├── android/                      # Android native code (Kotlin)
├── go_src/                       # Go dnstt library source
├── lib/                          # Flutter/Dart code
│   ├── screens/                  # UI screens
│   ├── providers/                # State management
│   ├── services/                 # VPN and storage services
│   └── models/                   # Data models
├── slipstream-plugin-android/    # Slipstream submodule (QUIC-over-DNS)
├── picoquic.crosscompile.diff    # Patch for building Slipstream
├── macos/                        # macOS platform
├── windows/                      # Windows platform
├── linux/                        # Linux platform
└── scripts/                      # Build scripts
```

## Configuration

The app requires:
- **DNSTT Config**: Tunnel domain and public key from your dnstt server
- **DNS Server**: A DNS resolver that can reach your dnstt server

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
