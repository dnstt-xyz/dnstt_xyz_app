#!/bin/bash

# Build script for macOS version of DNSTT Client
# This script builds the Go library and Flutter app, then packages everything together

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GO_SRC_DIR="$PROJECT_DIR/go_src"
BUILD_TYPE="${1:-debug}"

echo "=== DNSTT Client macOS Build Script ==="
echo "Build type: $BUILD_TYPE"
echo "Project directory: $PROJECT_DIR"

# Step 1: Build Go library for macOS
echo ""
echo "=== Step 1: Building Go library ==="
cd "$GO_SRC_DIR"

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "Error: Go is not installed. Please install Go 1.21+ first."
    exit 1
fi

# Build the dylib
# -trimpath removes filesystem paths from binary (privacy)
# -ldflags="-s -w" strips debug info and symbol table (smaller size)
echo "Building libdnstt.dylib..."
CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -buildmode=c-shared -o libdnstt.dylib ./desktop

if [ ! -f "libdnstt.dylib" ]; then
    echo "Error: Failed to build libdnstt.dylib"
    exit 1
fi

# Copy to macos/Runner/Libraries for the build process
mkdir -p "$PROJECT_DIR/macos/Runner/Libraries"
cp libdnstt.dylib "$PROJECT_DIR/macos/Runner/Libraries/"
echo "Go library built successfully"

# Step 2: Build Flutter app
echo ""
echo "=== Step 2: Building Flutter app ==="
cd "$PROJECT_DIR"

# Get dependencies
flutter pub get

# Build the app
if [ "$BUILD_TYPE" = "release" ]; then
    flutter build macos --release
    APP_PATH="$PROJECT_DIR/build/macos/Build/Products/Release/DNSTT_XYZ.app"
else
    flutter build macos --debug
    APP_PATH="$PROJECT_DIR/build/macos/Build/Products/Debug/DNSTT_XYZ.app"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Failed to build Flutter app"
    exit 1
fi

echo "Flutter app built successfully"

# Step 3: Copy dylib to app bundle
echo ""
echo "=== Step 3: Packaging dylib into app bundle ==="

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
cp "$GO_SRC_DIR/libdnstt.dylib" "$FRAMEWORKS_DIR/"

# Update dylib install name
install_name_tool -id "@rpath/libdnstt.dylib" "$FRAMEWORKS_DIR/libdnstt.dylib"

# Sign the dylib (ad-hoc signing for development)
codesign --force --sign - "$FRAMEWORKS_DIR/libdnstt.dylib"

echo "Dylib packaged successfully"

# Step 3b: Bundle slipstream-client binary (if available)
SLIPSTREAM_SRC="$PROJECT_DIR/macos/Runner/Libraries/slipstream-client"
if [ -f "$SLIPSTREAM_SRC" ]; then
    echo ""
    echo "=== Step 3b: Bundling slipstream-client ==="
    cp "$SLIPSTREAM_SRC" "$FRAMEWORKS_DIR/slipstream-client"
    chmod +x "$FRAMEWORKS_DIR/slipstream-client"

    # Bundle OpenSSL dylibs required by slipstream-client (picoquic links dynamically)
    # Find OpenSSL from homebrew or the system
    OPENSSL_LIB_DIR=""
    if [ -d "/opt/homebrew/opt/openssl@3/lib" ]; then
        OPENSSL_LIB_DIR="/opt/homebrew/opt/openssl@3/lib"
    elif [ -d "/usr/local/opt/openssl@3/lib" ]; then
        OPENSSL_LIB_DIR="/usr/local/opt/openssl@3/lib"
    fi

    if [ -n "$OPENSSL_LIB_DIR" ]; then
        echo "Bundling OpenSSL dylibs from $OPENSSL_LIB_DIR"
        # Remove old copies first (they may be read-only from previous builds)
        rm -f "$FRAMEWORKS_DIR/libssl.3.dylib" "$FRAMEWORKS_DIR/libcrypto.3.dylib"
        cp "$OPENSSL_LIB_DIR/libssl.3.dylib" "$FRAMEWORKS_DIR/"
        cp "$OPENSSL_LIB_DIR/libcrypto.3.dylib" "$FRAMEWORKS_DIR/"
        chmod +rw "$FRAMEWORKS_DIR/libssl.3.dylib" "$FRAMEWORKS_DIR/libcrypto.3.dylib"

        # Fix slipstream-client to load OpenSSL from @rpath instead of absolute homebrew paths
        install_name_tool -change "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib" "@rpath/libssl.3.dylib" "$FRAMEWORKS_DIR/slipstream-client"
        install_name_tool -change "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib" "@rpath/libcrypto.3.dylib" "$FRAMEWORKS_DIR/slipstream-client"
        install_name_tool -change "/usr/local/opt/openssl@3/lib/libssl.3.dylib" "@rpath/libssl.3.dylib" "$FRAMEWORKS_DIR/slipstream-client"
        install_name_tool -change "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib" "@rpath/libcrypto.3.dylib" "$FRAMEWORKS_DIR/slipstream-client"
        # Add @loader_path as rpath so it finds dylibs next to itself
        install_name_tool -add_rpath @loader_path "$FRAMEWORKS_DIR/slipstream-client" 2>/dev/null || true

        # Fix libssl to reference libcrypto via @rpath too
        install_name_tool -change "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib" "@rpath/libcrypto.3.dylib" "$FRAMEWORKS_DIR/libssl.3.dylib"
        install_name_tool -change "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib" "@rpath/libcrypto.3.dylib" "$FRAMEWORKS_DIR/libssl.3.dylib"
        install_name_tool -id "@rpath/libssl.3.dylib" "$FRAMEWORKS_DIR/libssl.3.dylib"
        install_name_tool -id "@rpath/libcrypto.3.dylib" "$FRAMEWORKS_DIR/libcrypto.3.dylib"

        # Sign OpenSSL dylibs
        codesign --force --sign - "$FRAMEWORKS_DIR/libcrypto.3.dylib"
        codesign --force --sign - "$FRAMEWORKS_DIR/libssl.3.dylib"
        echo "OpenSSL dylibs bundled and patched"
    else
        echo "WARNING: OpenSSL 3 not found. slipstream-client may fail to load."
        echo "  Install with: brew install openssl@3"
    fi

    # Sign slipstream-client with com.apple.security.inherit entitlement
    # This allows the subprocess to inherit the parent app's sandbox capabilities (network access)
    INHERIT_ENTITLEMENTS="$PROJECT_DIR/macos/Runner/SlipstreamInherit.entitlements"
    if [ ! -f "$INHERIT_ENTITLEMENTS" ]; then
        cat > "$INHERIT_ENTITLEMENTS" << 'ENTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.inherit</key>
	<true/>
</dict>
</plist>
ENTEOF
    fi
    codesign --force --sign - --entitlements "$INHERIT_ENTITLEMENTS" "$FRAMEWORKS_DIR/slipstream-client"
    echo "slipstream-client bundled and signed with inherit entitlement"
else
    echo ""
    echo "Note: slipstream-client not found at $SLIPSTREAM_SRC (skipping)"
    echo "  Run ./scripts/build_slipstream_desktop.sh to bundle it"
fi

# Step 4: Re-sign the entire app bundle
echo ""
echo "=== Step 4: Re-signing app bundle ==="
codesign --force --deep --sign - "$APP_PATH"

# Re-sign slipstream-client with inherit entitlement AFTER deep signing
# (deep signing strips per-binary entitlements, so we must re-apply)
if [ -f "$FRAMEWORKS_DIR/slipstream-client" ]; then
    INHERIT_ENTITLEMENTS="$PROJECT_DIR/macos/Runner/SlipstreamInherit.entitlements"
    codesign --force --sign - --entitlements "$INHERIT_ENTITLEMENTS" "$FRAMEWORKS_DIR/slipstream-client"
    echo "slipstream-client re-signed with inherit entitlement"
fi

echo "App bundle signed"

# Step 5: Verify the build
echo ""
echo "=== Build Complete ==="
echo "App location: $APP_PATH"
echo ""
echo "Contents:"
ls -la "$FRAMEWORKS_DIR/" 2>/dev/null || echo "  (no Frameworks)"
echo ""
echo "To run the app:"
echo "  open \"$APP_PATH\""
echo ""
echo "To create a DMG for distribution:"
echo "  hdiutil create -volname 'DNSTT_XYZ' -srcfolder \"$APP_PATH\" -ov -format UDZO DNSTT_XYZ.dmg"
