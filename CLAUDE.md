# DNSTT Client - Build & Development Guide

**Website**: https://dnstt.xyz
**GitHub**: https://github.com/dnstt-xyz/dnstt_xyz_app

## Overview

A cross-platform app that tunnels traffic through DNS using the dnstt protocol:
- **Android**: Full device VPN tunneling
- **Desktop** (macOS, Windows, Linux): SOCKS5 proxy mode

The app uses:
- **Flutter** for the UI and app logic
- **Kotlin** for Android VPN service implementation
- **Go (gomobile)** for the dnstt tunnel client library (source included in `go_src/`)

### How DNSTT Works

DNSTT tunnels data through DNS queries. The protocol stack:
1. **DNS Transport** - Data encoded in DNS TXT queries/responses
2. **KCP** - Reliable transport over UDP (DNS)
3. **Noise** - Encryption using Noise_NK protocol
4. **smux** - Multiplexed streams over the encrypted channel
5. **SOCKS5** - Local proxy interface for the VPN

Traffic flow:
```
App Traffic → TUN Interface → TCP State Machine → SOCKS5 → dnstt tunnel → DNS queries → Server
```

## Prerequisites

- Flutter SDK 3.x+
- Android SDK (API 21+) with NDK
- Go 1.21+
- gomobile: `go install golang.org/x/mobile/cmd/gomobile@latest`
- Java JDK 17

## Project Structure

```
dnstt_app/
├── android/
│   └── app/
│       ├── libs/
│       │   └── dnstt.aar               # Compiled Go dnstt library
│       ├── src/main/
│       │   ├── AndroidManifest.xml
│       │   └── kotlin/xyz/dnstt/app/
│       │       ├── MainActivity.kt      # Flutter platform channel bridge
│       │       ├── DnsttVpnService.kt   # Android VPN service + packet handling
│       │       ├── TcpConnection.kt     # TCP state machine for VPN
│       │       └── Socks5Client.kt      # SOCKS5 proxy client
│       └── build.gradle.kts
├── go_src/                              # Go dnstt library source (included in repo)
│   ├── mobile/
│   │   └── mobile.go                    # Go mobile bindings
│   ├── dns/                             # DNS encoding/decoding
│   ├── noise/                           # Noise encryption
│   ├── turbotunnel/                     # Tunnel management
│   ├── dnstt-client/                    # Original CLI client code
│   ├── dnstt-server/                    # Server code (reference)
│   ├── go.mod
│   └── go.sum
├── lib/
│   ├── main.dart                        # App entry point
│   ├── screens/
│   │   ├── home_screen.dart             # Main VPN control screen
│   │   ├── config_management_screen.dart # DNSTT config management
│   │   ├── dns_management_screen.dart   # DNS server management
│   │   ├── donate_screen.dart           # Donation/support page
│   │   └── test_screen.dart             # DNS server testing
│   ├── providers/
│   │   └── app_state.dart               # State management (Provider)
│   ├── services/
│   │   ├── vpn_service.dart             # Flutter VPN service wrapper
│   │   ├── storage_service.dart         # Local storage (SharedPreferences)
│   │   └── dnstt_service.dart           # DNSTT tunnel testing
│   └── models/
│       ├── dns_server.dart              # DNS server model
│       └── dnstt_config.dart            # DNSTT config model
├── pubspec.yaml
└── CLAUDE.md                            # This file
```

## Building the Go Mobile Library (AAR)

The dnstt client is compiled from Go to an Android AAR library.

### First Time Setup

```bash
# Install gomobile
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest

# Add to PATH
export PATH=$PATH:$HOME/go/bin

# Initialize gomobile (downloads Android NDK components)
gomobile init
```

### Build the AAR

**IMPORTANT**: Build from a temp directory to avoid embedding local paths in the binary.

```bash
# Copy source to temp directory and build from there
mkdir -p /tmp/dnstt_build
cp -r go_src/* /tmp/dnstt_build/
cd /tmp/dnstt_build

# Build for all architectures (largest file, most compatible)
# -trimpath removes local filesystem paths from binary
# -ldflags="-s -w" strips debug info (smaller size)
GOFLAGS="-trimpath" gomobile bind -ldflags="-s -w" -androidapi 21 -target=android -o dnstt.aar ./mobile

# Or build for specific architectures (smaller size)
GOFLAGS="-trimpath" gomobile bind -ldflags="-s -w" -androidapi 21 -target=android/arm64 -o dnstt.aar ./mobile           # ARM64 only
GOFLAGS="-trimpath" gomobile bind -ldflags="-s -w" -androidapi 21 -target=android/arm,android/arm64 -o dnstt.aar ./mobile  # ARM + ARM64

# Copy to project libs folder
cp dnstt.aar /path/to/project/android/app/libs/
cp dnstt.aar /path/to/project/go_src/  # Keep a copy in go_src
```

### Go Mobile Targets

| Target | Architecture | Use Case |
|--------|-------------|----------|
| `android/arm` | ARMv7a (32-bit) | Older Android phones |
| `android/arm64` | ARM64 (64-bit) | Modern Android phones |
| `android/386` | x86 (32-bit) | Old emulators |
| `android/amd64` | x86_64 (64-bit) | Modern emulators, Chromebooks |

## Building the Flutter App

### Install Dependencies

```bash
flutter pub get
```

### Debug Build

```bash
flutter build apk --debug
```
Output: `build/app/outputs/flutter-apk/app-debug.apk`

### Release Build (Fat APK - All Architectures)

```bash
flutter build apk --release
```
Output: `build/app/outputs/flutter-apk/app-release.apk`

### Split APKs by Architecture (Recommended)

```bash
flutter build apk --release --split-per-abi
```

Outputs:
| File | Architecture | Size |
|------|-------------|------|
| `app-armeabi-v7a-release.apk` | ARM 32-bit | ~22 MB |
| `app-arm64-v8a-release.apk` | ARM 64-bit | ~34 MB |
| `app-x86_64-release.apk` | x86_64 | ~28 MB |

### Build for Specific Architecture Only

```bash
# ARM64 (most modern phones)
flutter build apk --release --target-platform android-arm64

# ARM 32-bit (older phones)
flutter build apk --release --target-platform android-arm

# x86_64 (emulators)
flutter build apk --release --target-platform android-x64
```

### App Bundle (For Play Store)

```bash
flutter build appbundle --release
```
Output: `build/app/outputs/bundle/release/app-release.aab`

## Android Configuration

### Version Configuration

Edit `android/app/build.gradle`:

```gradle
android {
    defaultConfig {
        applicationId "xyz.dnstt.app"
        minSdkVersion 21        // Android 5.0 minimum (required for VPN)
        targetSdkVersion 34     // Android 14
        versionCode 1
        versionName "1.0.0"
    }
}
```

### Android Version Reference

| API | Version | Codename | Notes |
|-----|---------|----------|-------|
| 21 | 5.0 | Lollipop | Minimum for VpnService |
| 23 | 6.0 | Marshmallow | Runtime permissions |
| 26 | 8.0 | Oreo | Background limits |
| 28 | 9.0 | Pie | |
| 29 | 10 | Q | Scoped storage |
| 30 | 11 | R | |
| 31 | 12 | S | |
| 33 | 13 | Tiramisu | |
| 34 | 14 | Upside Down Cake | |

### AAR Dependency Configuration

In `android/app/build.gradle`:

```gradle
dependencies {
    implementation fileTree(dir: 'libs', include: ['*.aar'])
    // ... other dependencies
}
```

## Signing Release Builds

### Create Keystore

```bash
keytool -genkey -v \
  -keystore ~/dnstt-release-key.jks \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias dnstt-key
```

### Configure Signing

Create `android/key.properties`:
```properties
storePassword=your_store_password
keyPassword=your_key_password
keyAlias=dnstt-key
storeFile=/Users/yourname/dnstt-release-key.jks
```

Update `android/app/build.gradle`:
```gradle
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }
    buildTypes {
        release {
            signingConfig signingConfigs.release
        }
    }
}
```

## Key Components

### DnsttVpnService.kt

The Android VPN service that:
- Creates TUN interface for capturing traffic
- Excludes the app itself from VPN routing (so dnstt UDP packets bypass VPN)
- Processes IP packets from TUN
- Routes TCP through SOCKS5 proxy (dnstt tunnel)
- Handles DNS queries directly

### TcpConnection.kt

TCP state machine that:
- Handles SYN/ACK/FIN handshakes
- Tracks sequence/acknowledgment numbers
- Forwards data to SOCKS5 proxy
- Sends responses back through TUN

### mobile.go (Go)

The dnstt client library that:
- Creates DNS-encoded tunnel
- Handles Noise encryption
- Manages KCP reliable transport
- Provides SOCKS5 proxy interface on localhost:7000

## Development Workflow

### Making Changes to Go Code

```bash
# Edit Go code (source is in go_src/)
vim go_src/mobile/mobile.go

# Rebuild AAR
cd go_src
gomobile bind -v -androidapi 21 -target=android -o dnstt.aar ./mobile

# Copy to libs
cp dnstt.aar ../android/app/libs/

# Rebuild Flutter app
cd ..
flutter clean
flutter build apk --debug
```

### Testing on Device/Emulator

```bash
# Check connected devices
adb devices

# Check device architecture
adb shell getprop ro.product.cpu.abi

# Install APK
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# View logs
adb logcat | grep -E "(DnsttVpnService|flutter|dnstt)"

# Clear logs and watch
adb logcat -c && adb logcat | grep DnsttVpnService
```

## Troubleshooting

### gomobile not found
```bash
export PATH=$PATH:$HOME/go/bin
gomobile init
```

### gobind not found
```bash
go install golang.org/x/mobile/cmd/gobind@latest
```

### AAR build fails with NDK error
```bash
# Ensure NDK is installed via Android Studio SDK Manager
# Or set ANDROID_NDK_HOME
export ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/25.2.9519653
```

### App crashes on connect
Check logs:
```bash
adb logcat | grep -E "(FATAL|Exception|DnsttVpnService)"
```

### VPN permission denied
Ensure AndroidManifest.xml has:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>

<service
    android:name=".DnsttVpnService"
    android:exported="false"
    android:foregroundServiceType="specialUse"
    android:permission="android.permission.BIND_VPN_SERVICE">
    <intent-filter>
        <action android:name="android.net.VpnService"/>
    </intent-filter>
</service>
```

### Tunnel not stable / UDP errors
The dnstt UDP socket may get routed through the VPN despite app exclusion. The code includes:
- App exclusion via `addDisallowedApplication(packageName)`
- 1-second delay after VPN establishment before starting dnstt
- IPv4-only UDP socket binding

## Quick Reference

```bash
# === FULL BUILD FROM SCRATCH ===

# 1. Build Go library (from project root)
cd go_src
gomobile bind -v -androidapi 21 -target=android -o dnstt.aar ./mobile
cp dnstt.aar ../android/app/libs/
cd ..

# 2. Build Flutter app
flutter clean
flutter pub get
flutter build apk --release --split-per-abi

# === QUICK COMMANDS ===

# Debug build
flutter build apk --debug

# Release build (all architectures)
flutter build apk --release

# Split by architecture (recommended for distribution)
flutter build apk --release --split-per-abi

# ARM64 only
flutter build apk --release --target-platform android-arm64

# Install on device
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

# Run with logs
flutter run --release

# Watch logs
adb logcat | grep DnsttVpnService
```

## APK Output Sizes

When building with `--split-per-abi`:

| APK | Architecture | Size |
|-----|--------------|------|
| `app-armeabi-v7a-release.apk` | ARM 32-bit | ~17 MB |
| `app-arm64-v8a-release.apk` | ARM 64-bit | ~20 MB |
| `app-x86_64-release.apk` | x86_64 | ~22 MB |

## Cleaning APKs (Remove Metadata)

Release APKs contain build metadata that may include version info and paths. To remove this metadata for distribution:

### Quick Clean (Recommended)

```bash
cd build/app/outputs/flutter-apk

# Set up Android SDK tools
ANDROID_SDK="$HOME/Library/Android/sdk"
BUILD_TOOLS=$(ls -d "$ANDROID_SDK/build-tools"/*/ | tail -1)
APKSIGNER="$BUILD_TOOLS/apksigner"
DEBUG_KEYSTORE="$HOME/.android/debug.keystore"

# Create clean directory
mkdir -p clean_apks

# Process each APK
for apk in app-*-release.apk; do
  # Copy original
  cp "$apk" "clean_apks/$apk"

  # Remove metadata files
  zip -d "clean_apks/$apk" \
    "META-INF/com/android/build/gradle/app-metadata.properties" \
    "META-INF/version-control-info.textproto" \
    2>/dev/null || true

  # Re-sign the APK
  "$APKSIGNER" sign --ks "$DEBUG_KEYSTORE" \
    --ks-pass pass:android --key-pass pass:android \
    "clean_apks/$apk"
done

# Remove extended attributes (macOS)
xattr -c clean_apks/*.apk 2>/dev/null
```

### What Gets Removed

| File | Contents |
|------|----------|
| `app-metadata.properties` | Gradle plugin version |
| `version-control-info.textproto` | VCS/Git info |
| Extended attributes | macOS file metadata |

### Verify Clean APKs

```bash
# Check metadata is removed
for apk in clean_apks/*.apk; do
  echo "--- $(basename $apk) ---"
  if unzip -l "$apk" | grep -qE "app-metadata|version-control"; then
    echo "WARNING: Metadata present"
  else
    echo "Metadata removed ✓"
  fi
done

# Verify signatures
for apk in clean_apks/*.apk; do
  "$APKSIGNER" verify "$apk" && echo "$(basename $apk): Valid ✓"
done
```

### Notes

- Clean APKs are saved to `build/app/outputs/flutter-apk/clean_apks/`
- The signing uses debug keystore; for production, use your release keystore
- Some debug paths may remain embedded in native `.so` files (from Flutter/Go compilers); to fully remove these, build on a CI server or Docker container

## DNSTT Config Format

The app uses configs with:
- **Name**: Display name
- **Tunnel Domain**: e.g., `tunnel.example.com`
- **Public Key**: Noise public key in hex format

DNS servers are tested against the tunnel to find working ones.

---

## Desktop Builds (macOS, Windows, Linux)

The app also supports desktop platforms. On desktop, instead of creating a system-wide VPN, it runs a local SOCKS5 proxy that applications can be configured to use.

### Desktop Architecture

On desktop platforms:
- **Go Library**: Compiled as a native shared library (`.dylib` on macOS, `.dll` on Windows, `.so` on Linux)
- **FFI Bindings**: Dart FFI is used to call the Go library directly
- **SOCKS5 Proxy**: The dnstt tunnel runs as a local SOCKS5 proxy on `127.0.0.1:7000`
- **No VPN**: Users must configure their applications to use the SOCKS5 proxy

### Project Structure (Desktop)

```
dnstt_app/
├── go_src/
│   └── desktop/
│       └── desktop.go              # C-compatible FFI bindings for desktop
├── lib/services/
│   ├── vpn_service.dart            # Updated to support desktop (FFI mode)
│   └── dnstt_ffi_service.dart      # Dart FFI bindings for desktop
├── macos/
│   ├── Runner/
│   │   ├── Libraries/
│   │   │   └── libdnstt.dylib      # Go library for macOS
│   │   ├── DebugProfile.entitlements
│   │   └── Release.entitlements
│   └── Podfile
├── windows/                         # Windows platform support
├── linux/                           # Linux platform support
└── scripts/
    ├── build_macos.sh              # macOS build script
    ├── build_windows.sh            # Windows build script
    └── build_linux.sh              # Linux build script
```

### Building for macOS (Apple Silicon M1/M2/M3)

#### Quick Build

```bash
# Use the build script
./scripts/build_macos.sh release

# Or for debug build
./scripts/build_macos.sh debug
```

#### Manual Build

```bash
# 1. Build Go library
cd go_src
CGO_ENABLED=1 go build -buildmode=c-shared -o libdnstt.dylib ./desktop

# 2. Copy to project
mkdir -p ../macos/Runner/Libraries
cp libdnstt.dylib ../macos/Runner/Libraries/
cd ..

# 3. Build Flutter app
flutter pub get
flutter build macos --release

# 4. Copy dylib to app bundle
cp go_src/libdnstt.dylib build/macos/Build/Products/Release/DNSTT_XYZ.app/Contents/Frameworks/

# 5. Sign the dylib
codesign --force --sign - build/macos/Build/Products/Release/DNSTT_XYZ.app/Contents/Frameworks/libdnstt.dylib

# 6. Re-sign the app
codesign --force --sign - build/macos/Build/Products/Release/DNSTT_XYZ.app
```

#### Output Location

- Debug: `build/macos/Build/Products/Debug/DNSTT_XYZ.app`
- Release: `build/macos/Build/Products/Release/DNSTT_XYZ.app`

#### Create DMG for Distribution

```bash
hdiutil create -volname "DNSTT Client" \
  -srcfolder build/macos/Build/Products/Release/DNSTT_XYZ.app \
  -ov -format UDZO DNSTT_XYZ.dmg
```

### Building for Windows

Windows builds require:
- Windows 10+ or Windows cross-compilation toolchain (MinGW-w64)
- Visual Studio 2019+ with C++ desktop development tools

```bash
# Use the build script (on Windows)
./scripts/build_windows.sh release
```

#### Manual Build (Windows)

```bash
# 1. Build Go library
cd go_src
CGO_ENABLED=1 go build -buildmode=c-shared -o dnstt.dll ./desktop

# 2. Build Flutter app
cd ..
flutter pub get
flutter build windows --release

# 3. Copy DLL to output
cp go_src/dnstt.dll build/windows/x64/runner/Release/
```

### Building for Linux

Linux builds require:
- GCC and standard development tools
- GTK3 development libraries

```bash
# Ubuntu/Debian prerequisites
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev

# Use the build script
./scripts/build_linux.sh release
```

#### Manual Build (Linux)

```bash
# 1. Build Go library
cd go_src
CGO_ENABLED=1 go build -buildmode=c-shared -o libdnstt.so ./desktop

# 2. Build Flutter app
cd ..
flutter pub get
flutter build linux --release

# 3. Copy library to output
cp go_src/libdnstt.so build/linux/x64/release/bundle/lib/
```

### Desktop Usage

On desktop, the app provides a SOCKS5 proxy instead of a system-wide VPN:

1. **Connect**: Click the power button to start the tunnel
2. **Proxy Address**: When connected, the app shows `socks5://127.0.0.1:7000`
3. **Configure Apps**: Set your browser/apps to use the SOCKS5 proxy

#### Browser Configuration

**Firefox:**
1. Settings → Network Settings → Manual proxy configuration
2. SOCKS Host: `127.0.0.1`, Port: `7000`
3. Select SOCKS v5

**Chrome (via command line):**
```bash
google-chrome --proxy-server="socks5://127.0.0.1:7000"
```

**System Proxy (macOS):**
1. System Preferences → Network → Advanced → Proxies
2. Check "SOCKS Proxy"
3. Server: `127.0.0.1`, Port: `7000`

### Desktop Entitlements (macOS)

The app requires network entitlements. These are configured in:
- `macos/Runner/DebugProfile.entitlements`
- `macos/Runner/Release.entitlements`

Required entitlements:
```xml
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

### Desktop Quick Reference

```bash
# === macOS ===
./scripts/build_macos.sh release
open build/macos/Build/Products/Release/DNSTT_XYZ.app

# === Windows ===
./scripts/build_windows.sh release
# Run: build\windows\x64\runner\Release\dnstt_xyz_app.exe

# === Linux ===
./scripts/build_linux.sh release
./build/linux/x64/release/bundle/dnstt_xyz_app
```
