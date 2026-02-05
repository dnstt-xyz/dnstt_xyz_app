#!/bin/bash

# Build script for cross-compiling Slipstream native library for Android
# This script cross-compiles the Rust slipstream library using cargo-ndk
# and places the resulting .so files in the Android jniLibs directories.
#
# Prerequisites:
#   - Rust toolchain (rustup)
#   - Android NDK
#   - cargo-ndk: cargo install cargo-ndk
#   - Rust Android targets:
#     rustup target add aarch64-linux-android
#     rustup target add armv7-linux-androideabi
#     rustup target add i686-linux-android
#     rustup target add x86_64-linux-android
#
# Usage: ./scripts/build_slipstream_android.sh [path_to_slipstream_src]
#
# By default, uses the git submodule at vendor/slipstream-rust.
# Run `git submodule update --init --recursive` first.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SLIPSTREAM_SRC="${1:-$PROJECT_DIR/vendor/slipstream-rust}"
JNILIBS_DIR="$PROJECT_DIR/android/app/src/main/jniLibs"

echo "=== Slipstream Android Build Script ==="
echo "Project directory: $PROJECT_DIR"
echo "Slipstream source: $SLIPSTREAM_SRC"
echo "JNI libs output: $JNILIBS_DIR"

# Check prerequisites
if ! command -v cargo &> /dev/null; then
    echo "Error: Rust/Cargo is not installed."
    echo "Install from: https://rustup.rs/"
    exit 1
fi

if ! command -v cargo-ndk &> /dev/null; then
    echo "Error: cargo-ndk is not installed."
    echo "Install with: cargo install cargo-ndk"
    exit 1
fi

if [ ! -d "$SLIPSTREAM_SRC" ] || [ ! -f "$SLIPSTREAM_SRC/Cargo.toml" ]; then
    echo "Error: Slipstream source not found at $SLIPSTREAM_SRC"
    echo "Run: git submodule update --init --recursive"
    echo "Or provide a path: $0 [path_to_slipstream_src]"
    exit 1
fi

# Check Android NDK
if [ -z "$ANDROID_NDK_HOME" ]; then
    # Try common locations
    if [ -d "$HOME/Library/Android/sdk/ndk" ]; then
        ANDROID_NDK_HOME=$(ls -d "$HOME/Library/Android/sdk/ndk"/*/ 2>/dev/null | tail -1 | sed 's/\/$//')
    elif [ -d "$ANDROID_HOME/ndk" ]; then
        ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME/ndk"/*/ 2>/dev/null | tail -1 | sed 's/\/$//')
    fi

    if [ -z "$ANDROID_NDK_HOME" ]; then
        echo "Error: ANDROID_NDK_HOME is not set and NDK could not be found."
        echo "Please set ANDROID_NDK_HOME or install NDK via Android Studio."
        exit 1
    fi
fi

echo "Android NDK: $ANDROID_NDK_HOME"

# Create output directories
mkdir -p "$JNILIBS_DIR/arm64-v8a"
mkdir -p "$JNILIBS_DIR/armeabi-v7a"
mkdir -p "$JNILIBS_DIR/x86"
mkdir -p "$JNILIBS_DIR/x86_64"

# Build for each target
cd "$SLIPSTREAM_SRC"

echo ""
echo "=== Building for aarch64 (arm64-v8a) ==="
cargo ndk -t aarch64-linux-android -o "$JNILIBS_DIR" build --release

echo ""
echo "=== Building for armv7 (armeabi-v7a) ==="
cargo ndk -t armv7-linux-androideabi -o "$JNILIBS_DIR" build --release

echo ""
echo "=== Building for i686 (x86) ==="
cargo ndk -t i686-linux-android -o "$JNILIBS_DIR" build --release

echo ""
echo "=== Building for x86_64 ==="
cargo ndk -t x86_64-linux-android -o "$JNILIBS_DIR" build --release

# Verify outputs
echo ""
echo "=== Verifying outputs ==="
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    SO_FILE="$JNILIBS_DIR/$abi/libslipstream.so"
    if [ -f "$SO_FILE" ]; then
        SIZE=$(ls -lh "$SO_FILE" | awk '{print $5}')
        echo "  $abi: $SO_FILE ($SIZE)"
    else
        echo "  WARNING: $abi: libslipstream.so not found!"
    fi
done

echo ""
echo "=== Build Complete ==="
echo "JNI libraries placed in: $JNILIBS_DIR"
