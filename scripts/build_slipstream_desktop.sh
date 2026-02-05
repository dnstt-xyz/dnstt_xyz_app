#!/bin/bash

# Build script for Slipstream client binary for desktop platforms.
# Builds from the git submodule at vendor/slipstream-rust and copies
# the binary to the appropriate platform location for bundling.
#
# Usage:
#   ./scripts/build_slipstream_desktop.sh          # build from submodule
#   ./scripts/build_slipstream_desktop.sh --binary path/to/binary  # use pre-built binary
#
# Prerequisites (when building from source):
#   - Rust toolchain (rustup)
#   - cmake, pkg-config, OpenSSL dev headers
#   - Run: git submodule update --init --recursive

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SLIPSTREAM_SRC="$PROJECT_DIR/vendor/slipstream-rust"
PREBUILT_BINARY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)
            PREBUILT_BINARY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--binary path/to/binary]"
            exit 1
            ;;
    esac
done

echo "=== Slipstream Client Desktop Build ==="
echo "Project directory: $PROJECT_DIR"

if [ -n "$PREBUILT_BINARY" ]; then
    # Use pre-built binary
    if [ ! -f "$PREBUILT_BINARY" ]; then
        echo "Error: Binary not found at $PREBUILT_BINARY"
        exit 1
    fi
    BINARY_PATH="$PREBUILT_BINARY"
    echo "Using pre-built binary: $BINARY_PATH"
else
    # Build from submodule source
    if [ ! -f "$SLIPSTREAM_SRC/Cargo.toml" ]; then
        echo "Error: Slipstream source not found at $SLIPSTREAM_SRC"
        echo "Run: git submodule update --init --recursive"
        exit 1
    fi

    if ! command -v cargo &> /dev/null; then
        echo "Error: Rust/Cargo is not installed."
        echo "Install from: https://rustup.rs/"
        exit 1
    fi

    echo "Building slipstream-client from source..."
    cd "$SLIPSTREAM_SRC"

    # Initialize picoquic submodule if needed
    if [ ! -f "vendor/picoquic/CMakeLists.txt" ]; then
        echo "Initializing picoquic submodule..."
        git submodule update --init --recursive
    fi

    cargo build -p slipstream-client --release

    BINARY_PATH="$SLIPSTREAM_SRC/target/release/slipstream-client"
    if [ ! -f "$BINARY_PATH" ]; then
        echo "Error: Build succeeded but binary not found at $BINARY_PATH"
        exit 1
    fi
    echo "Build successful: $BINARY_PATH"
fi

# Copy to platform-specific location
case "$(uname -s)" in
    Darwin)
        echo "Platform: macOS"
        DEST_DIR="$PROJECT_DIR/macos/Runner/Libraries"
        mkdir -p "$DEST_DIR"
        cp "$BINARY_PATH" "$DEST_DIR/slipstream-client"
        chmod +x "$DEST_DIR/slipstream-client"
        echo "Binary staged at $DEST_DIR/slipstream-client"
        echo "It will be bundled into Frameworks/ by build_macos.sh"
        ;;
    Linux)
        echo "Platform: Linux"
        DEST_DIR="$PROJECT_DIR/linux/tools"
        mkdir -p "$DEST_DIR"
        cp "$BINARY_PATH" "$DEST_DIR/slipstream-client"
        chmod +x "$DEST_DIR/slipstream-client"
        echo "Binary staged at $DEST_DIR/slipstream-client"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "Platform: Windows"
        DEST_DIR="$PROJECT_DIR/windows/runner/tools"
        mkdir -p "$DEST_DIR"
        cp "$BINARY_PATH" "$DEST_DIR/slipstream-client.exe"
        echo "Binary staged at $DEST_DIR/slipstream-client.exe"
        ;;
    *)
        echo "Error: Unsupported platform: $(uname -s)"
        exit 1
        ;;
esac

echo ""
echo "=== Done ==="
