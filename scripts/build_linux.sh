#!/bin/bash

# Build script for Linux version of DNSTT Client
# This script builds the Go library and Flutter app for Linux

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GO_SRC_DIR="$PROJECT_DIR/go_src"
BUILD_TYPE="${1:-release}"

echo "=== DNSTT Client Linux Build Script ==="
echo "Build type: $BUILD_TYPE"
echo "Project directory: $PROJECT_DIR"

# Step 1: Build Go library for Linux
echo ""
echo "=== Step 1: Building Go library ==="
cd "$GO_SRC_DIR"

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "Error: Go is not installed. Please install Go 1.21+ first."
    exit 1
fi

# Build the shared library
# -trimpath removes filesystem paths from binary (privacy)
# -ldflags="-s -w" strips debug info and symbol table (smaller size)
echo "Building libdnstt.so..."
CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -buildmode=c-shared -o libdnstt.so ./desktop

if [ ! -f "libdnstt.so" ]; then
    echo "Error: Failed to build libdnstt.so"
    exit 1
fi

echo "Go library built successfully"

# Step 2: Build Flutter app
echo ""
echo "=== Step 2: Building Flutter app ==="
cd "$PROJECT_DIR"

# Get dependencies
flutter pub get

# Build the app
if [ "$BUILD_TYPE" = "release" ]; then
    flutter build linux --release
    APP_PATH="$PROJECT_DIR/build/linux/x64/release/bundle"
else
    flutter build linux --debug
    APP_PATH="$PROJECT_DIR/build/linux/x64/debug/bundle"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Failed to build Flutter app"
    exit 1
fi

echo "Flutter app built successfully"

# Step 3: Copy shared library to app directory
echo ""
echo "=== Step 3: Copying library to app directory ==="

LIB_DIR="$APP_PATH/lib"
mkdir -p "$LIB_DIR"
cp "$GO_SRC_DIR/libdnstt.so" "$LIB_DIR/"

echo "Library copied successfully"

echo ""
echo "=== Build Complete ==="
echo "App location: $APP_PATH"
echo "Executable: $APP_PATH/dnstt_xyz_app"
echo ""
echo "To run the app:"
echo "  cd \"$APP_PATH\" && ./dnstt_xyz_app"
echo ""
echo "To create a tarball for distribution:"
echo "  tar -czvf dnstt_linux.tar.gz -C \"$APP_PATH\" ."
