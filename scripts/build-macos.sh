#!/usr/bin/env bash
# macOS 构建（R9）：flutter build macos --release（或 --debug），Rust 核心由 cargokit 在 Xcode Run Script Phase
# （macos/Scripts/bundle_rust_and_fonts.sh → cargokit/build_pod.sh）里随 Runner 构建并打入 Contents/Frameworks/libacp_bridge.dylib。
#   bash scripts/build-macos.sh                   # release
#   bash scripts/build-macos.sh --debug           # debug
#   bash scripts/build-macos.sh --smoke           # 构建后跑一次无头往返自检（ACP_SMOKE_REPORT + -t lib/main_headless.dart）
#   bash scripts/build-macos.sh --target <dart>   # 指定入口（如 lib/main_headless.dart）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$HOME/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

MODE="release"
CONFIG="Release"
SMOKE=0
TARGET="lib/main.dart"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug|-Debug)
      MODE="debug"
      CONFIG="Debug"
      shift
      ;;
    --release|-Release)
      MODE="release"
      CONFIG="Release"
      shift
      ;;
    --smoke|-Smoke)
      SMOKE=1
      shift
      ;;
    --target|-t)
      TARGET="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT"

echo "== flutter build macos --$MODE -t $TARGET"
flutter build macos "--$MODE" -t "$TARGET"

APP_DIR="$ROOT/build/macos/Build/Products/$CONFIG/acp_agent_client.app"
EXE="$APP_DIR/Contents/MacOS/acp_agent_client"
DYLIB="$APP_DIR/Contents/Frameworks/libacp_bridge.dylib"

for f in "$EXE" "$DYLIB"; do
  if [ ! -f "$f" ]; then
    echo "expected build output missing: $f" >&2
    exit 1
  fi
done

echo "OK  $EXE ($(wc -c < "$EXE" | tr -d ' ') bytes)"
echo "OK  $DYLIB ($(wc -c < "$DYLIB" | tr -d ' ') bytes)"

if [ "$SMOKE" = 1 ]; then
  REPORT="$ROOT/build/smoke-report.json"
  rm -f "$REPORT"
  echo "== smoke: $EXE (ACP_SMOKE_REPORT=$REPORT)"
  ACP_SMOKE_REPORT="$REPORT" "$EXE"
  if [ ! -f "$REPORT" ]; then
    echo "smoke produced no report: $REPORT" >&2
    exit 1
  fi
  cat "$REPORT"
  echo ""
  echo "OK  smoke round trip (ACP_SMOKE_REPORT)"

  if [ "$TARGET" = "lib/main.dart" ]; then
    echo "== headless target check (-t lib/main_headless.dart)"
    flutter build macos "--$MODE" -t lib/main_headless.dart
    HEADLESS_OUT="$ROOT/build/headless-smoke.json"
    HEADLESS_DATA="$(mktemp -d "${TMPDIR:-/tmp}/acp-headless-smoke.XXXXXX")"
    rm -f "$HEADLESS_OUT"
    ACP_HEADLESS_MODE="r3" \
      ACP_HEADLESS_OUT="$HEADLESS_OUT" \
      ACP_HEADLESS_CWD="$ROOT" \
      ACP_HEADLESS_DATA_DIR="$HEADLESS_DATA" \
      ACP_HEADLESS_AGENT_CMD="node" \
      ACP_HEADLESS_AGENT_ARGS="$ROOT/test/fake-agent/fake-agent.mjs" \
      "$EXE"
    rm -rf "$HEADLESS_DATA"
    if [ ! -f "$HEADLESS_OUT" ]; then
      echo "headless run produced no report: $HEADLESS_OUT" >&2
      exit 1
    fi
    echo "OK  headless round trip (-t lib/main_headless.dart)"
    # Restore product entry point build
    flutter build macos "--$MODE" -t lib/main.dart
  fi
fi
