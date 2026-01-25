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

# Step 4: Re-sign the entire app bundle
echo ""
echo "=== Step 4: Re-signing app bundle ==="
codesign --force --deep --sign - "$APP_PATH"
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
