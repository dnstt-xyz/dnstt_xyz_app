#!/bin/bash

# Build script for Windows version of DNSTT Client
# This script builds the Go library and Flutter app for Windows
# Must be run on Windows or with a Windows cross-compilation toolchain

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GO_SRC_DIR="$PROJECT_DIR/go_src"
BUILD_TYPE="${1:-release}"

echo "=== DNSTT Client Windows Build Script ==="
echo "Build type: $BUILD_TYPE"
echo "Project directory: $PROJECT_DIR"

# Step 1: Build Go library for Windows
echo ""
echo "=== Step 1: Building Go library for Windows ==="
cd "$GO_SRC_DIR"

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "Error: Go is not installed. Please install Go 1.21+ first."
    exit 1
fi

# Build the DLL for Windows
echo "Building dnstt.dll..."
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "win32" ]]; then
    # Native Windows build
    CGO_ENABLED=1 go build -buildmode=c-shared -o dnstt.dll ./desktop
else
    # Cross-compilation from Linux/macOS (requires mingw-w64)
    echo "Cross-compiling for Windows (requires mingw-w64)..."
    GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc go build -buildmode=c-shared -o dnstt.dll ./desktop
fi

if [ ! -f "dnstt.dll" ]; then
    echo "Error: Failed to build dnstt.dll"
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
    flutter build windows --release
    APP_PATH="$PROJECT_DIR/build/windows/x64/runner/Release"
else
    flutter build windows --debug
    APP_PATH="$PROJECT_DIR/build/windows/x64/runner/Debug"
fi

echo "Flutter app built successfully"

# Step 3: Copy DLL to app directory
echo ""
echo "=== Step 3: Copying DLL to app directory ==="
cp "$GO_SRC_DIR/dnstt.dll" "$APP_PATH/"

echo ""
echo "=== Build Complete ==="
echo "App location: $APP_PATH"
echo ""
echo "To distribute, zip the contents of $APP_PATH"
