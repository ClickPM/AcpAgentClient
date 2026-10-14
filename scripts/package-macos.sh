#!/usr/bin/env bash
# macOS 打包（R9）：免安装 .zip 与 .dmg（不签名，与 Windows R8 口径一致）。
#   bash scripts/package-macos.sh                 # 构建 + zip + dmg
#   bash scripts/package-macos.sh --skip-build    # 直接用现有 build/macos/Build/Products/Release/acp_agent_client.app
#   bash scripts/package-macos.sh --no-dmg        # 只出 zip（跳过 hdiutil dmg）
# 产物落 dist/（gitignored）：
#   dist/AcpAgentClient-<版本>-macos-<arch>.zip
#   dist/AcpAgentClient-<版本>-macos-<arch>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$HOME/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

SKIP_BUILD=0
NO_DMG=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-build|-SkipBuild)
      SKIP_BUILD=1
      shift
      ;;
    --no-dmg|-NoDmg)
      NO_DMG=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT"

VERSION="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+[[:space:]]*$/\1/p' "$ROOT/pubspec.yaml" | head -n 1)"
if [ -z "$VERSION" ]; then
  echo "pubspec.yaml 里没有 version: X.Y.Z+N 行" >&2
  exit 1
fi

ARCH="$(uname -m)"
echo "== packaging AcpAgent Client $VERSION (macos-$ARCH)"

if [ "$SKIP_BUILD" = 0 ]; then
  bash "$ROOT/scripts/build-macos.sh" --smoke
fi

RELEASE_APP="$ROOT/build/macos/Build/Products/Release/acp_agent_client.app"
EXE="$RELEASE_APP/Contents/MacOS/acp_agent_client"
DYLIB="$RELEASE_APP/Contents/Frameworks/libacp_bridge.dylib"

for f in "$EXE" "$DYLIB"; do
  if [ ! -f "$f" ]; then
    echo "没有 release 产物：$f（先跑 scripts/build-macos.sh）" >&2
    exit 1
  fi
done

DIST="$ROOT/dist"
STAGE_ROOT="$DIST/stage"
NAME="AcpAgentClient-${VERSION}-macos-${ARCH}"
PAYLOAD="$STAGE_ROOT/$NAME"

rm -rf "$STAGE_ROOT"
mkdir -p "$PAYLOAD"

cp -R "$RELEASE_APP" "$PAYLOAD/AcpAgentClient.app"
# GPL-3.0-or-later：分发二进制要带许可证与派生文件清单（README「许可证」、NOTICE）。
cp -f "$ROOT/LICENSE" "$PAYLOAD/LICENSE"
cp -f "$ROOT/NOTICE" "$PAYLOAD/NOTICE"

ZIP_PATH="$DIST/${NAME}.zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$PAYLOAD" "$ZIP_PATH"
echo "OK  zip        $ZIP_PATH ($(wc -c < "$ZIP_PATH" | tr -d ' ') bytes)"

if [ "$NO_DMG" = 0 ] && command -v hdiutil >/dev/null 2>&1; then
  DMG_STAGE="$STAGE_ROOT/dmg-root"
  rm -rf "$DMG_STAGE"
  mkdir -p "$DMG_STAGE"
  cp -R "$PAYLOAD/AcpAgentClient.app" "$DMG_STAGE/AcpAgentClient.app"
  cp -f "$ROOT/LICENSE" "$DMG_STAGE/LICENSE"
  cp -f "$ROOT/NOTICE" "$DMG_STAGE/NOTICE"
  ln -s /Applications "$DMG_STAGE/Applications"

  DMG_PATH="$DIST/${NAME}.dmg"
  rm -f "$DMG_PATH"
  hdiutil create -volname "AcpAgent Client ${VERSION}" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  echo "OK  dmg        $DMG_PATH ($(wc -c < "$DMG_PATH" | tr -d ' ') bytes)"
fi
