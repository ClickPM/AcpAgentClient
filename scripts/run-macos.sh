#!/usr/bin/env bash
set -e

# AcpAgentClient macOS launch script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RELEASE_APP="$ROOT_DIR/build/macos/Build/Products/Release/acp_agent_client.app"
DEBUG_APP="$ROOT_DIR/build/macos/Build/Products/Debug/acp_agent_client.app"

TARGET_APP=""
if [ -d "$RELEASE_APP" ]; then
  TARGET_APP="$RELEASE_APP"
elif [ -d "$DEBUG_APP" ]; then
  TARGET_APP="$DEBUG_APP"
fi

if [ -n "$TARGET_APP" ]; then
  echo "Opening $TARGET_APP..."
  open "$TARGET_APP"
  exit 0
fi

echo "No built application found. Building first with ./scripts/build-macos.sh..."
"$SCRIPT_DIR/build-macos.sh"
