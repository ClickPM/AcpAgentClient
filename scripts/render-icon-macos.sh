#!/usr/bin/env bash
# design/brand/app-icon.svg -> macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_<size>.png
# 与 scripts/render-icon.ps1 同一几何来源与渲染方式（headless Chromium + 透明背景）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/design/brand/app-icon.svg"
OUT_DIR="$ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SVG" ]; then
  echo "error: source svg not found: $SVG" >&2
  exit 1
fi

BROWSER=""
for candidate in \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
  if [ -x "$candidate" ]; then
    BROWSER="$candidate"
    break
  fi
done

if [ -z "$BROWSER" ]; then
  echo "error: no Chromium browser found (Microsoft Edge or Google Chrome)" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/acp-icon-macos.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cp "$SVG" "$WORK/app-icon.svg"
mkdir -p "$OUT_DIR"

for s in 16 32 64 128 256 512 1024; do
  HTML="$WORK/f${s}.html"
  PNG="$OUT_DIR/app_icon_${s}.png"
  cat > "$HTML" <<EOF
<!doctype html><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:transparent}img{display:block;width:${s}px;height:${s}px}</style><img src="app-icon.svg">
EOF
  "$BROWSER" \
    --headless=new \
    --disable-gpu \
    --hide-scrollbars \
    --force-device-scale-factor=1 \
    --default-background-color=00000000 \
    --window-size="${s},${s}" \
    --screenshot="$PNG" \
    "file://$HTML" >/dev/null 2>&1
  if [ ! -s "$PNG" ]; then
    echo "error: failed to render $PNG" >&2
    exit 1
  fi
done

echo "wrote macOS app icons to $OUT_DIR (16, 32, 64, 128, 256, 512, 1024)"
