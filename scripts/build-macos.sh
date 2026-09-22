#!/usr/bin/env bash
set -e

# AcpAgentClient macOS build script
MODE="release"
RUST_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --debug)
      MODE="debug"
      shift
      ;;
    --rust-only)
      RUST_ONLY=true
      shift
      ;;
    *)
      echo "Usage: $0 [--debug] [--rust-only]"
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=================================================="
echo " AcpAgentClient macOS build ($MODE)"
echo " Root directory: $ROOT_DIR"
echo "=================================================="

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/acp_target}"
mkdir -p "$CARGO_TARGET_DIR"

BUILD_SRC="$ROOT_DIR"
if [[ "$ROOT_DIR" == *":"* ]]; then
  BUILD_SRC="/tmp/AcpAgentClient_build"
  rm -f "$BUILD_SRC" 2>/dev/null || true
  ln -s "$ROOT_DIR" "$BUILD_SRC"
  echo "== Safe directory symlink: $BUILD_SRC -> $ROOT_DIR"
fi

echo "== [1/3] Building Rust core dynamic library (libacp_bridge.dylib)..."
if [ "$MODE" = "release" ]; then
  cargo build --manifest-path "$BUILD_SRC/rust/bridge/Cargo.toml" --release
else
  cargo build --manifest-path "$BUILD_SRC/rust/bridge/Cargo.toml"
fi

DYLIB_SOURCE="$CARGO_TARGET_DIR/$MODE/libacp_bridge.dylib"
if [ ! -f "$DYLIB_SOURCE" ]; then
  echo "Error: Dynamic library not found at $DYLIB_SOURCE"
  exit 1
fi

mkdir -p "$BUILD_SRC/rust/bridge/target/release"
cp -f "$DYLIB_SOURCE" "$BUILD_SRC/rust/bridge/target/release/libacp_bridge.dylib"
echo "OK  Built dynamic library: $DYLIB_SOURCE"

if [ "$RUST_ONLY" = true ]; then
  echo "== Finished (--rust-only)"
  exit 0
fi

echo "== [2/3] Checking Flutter toolchain..."
FLUTTER_BIN="$(which flutter 2>/dev/null || true)"
if [ -z "$FLUTTER_BIN" ]; then
  echo "Error: Flutter SDK not found in PATH."
  exit 1
fi

echo "Using Flutter: $("$FLUTTER_BIN" --version | head -n 1)"

echo "== [3/3] Running flutter build macos..."
cd "$BUILD_SRC"
"$FLUTTER_BIN" pub get

if [ "$MODE" = "release" ]; then
  "$FLUTTER_BIN" build macos --release
else
  "$FLUTTER_BIN" build macos --debug
fi

APP_CONFIG="Release"
[ "$MODE" = "debug" ] && APP_CONFIG="Debug"
APP_BUNDLE="$BUILD_SRC/build/macos/Build/Products/$APP_CONFIG/acp_agent_client.app"

if [ -d "$APP_BUNDLE" ]; then
  mkdir -p "$APP_BUNDLE/Contents/Frameworks/acp_bridge.framework"
  cp -f "$DYLIB_SOURCE" "$APP_BUNDLE/Contents/Frameworks/libacp_bridge.dylib"
  cp -f "$DYLIB_SOURCE" "$APP_BUNDLE/Contents/Frameworks/acp_bridge.framework/acp_bridge"
  if [ -d "$BUILD_SRC/assets/fonts/optional" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/fonts"
    cp -f "$BUILD_SRC/assets/fonts/optional"/*.* "$APP_BUNDLE/Contents/Resources/fonts/" 2>/dev/null || true
  fi
  codesign --force --deep --sign - "$APP_BUNDLE/Contents/Frameworks/libacp_bridge.dylib" 2>/dev/null || true
  codesign --force --deep --sign - "$APP_BUNDLE/Contents/Frameworks/acp_bridge.framework/acp_bridge" 2>/dev/null || true
  codesign --force --sign - "$APP_BUNDLE" 2>/dev/null || true

  echo "=================================================="
  echo "Build successful: $APP_BUNDLE"
  echo "Launch with: open "$APP_BUNDLE""
  echo "=================================================="
fi
