#!/usr/bin/env bash
# Xcode Run Script Phase（R9）：
# 1. 经仓库内 `cargokit/build_pod.sh`（→ `cargokit/run_build_tool.sh`）按当前 CONFIGURATION / ARCHS 编译 `rust/bridge`（`acp_bridge`），
#    将产物 `libacp_bridge.dylib` 打入 App Bundle 的 `Contents/Frameworks/`；
# 2. 对齐 `windows/CMakeLists.txt` 的可选字体安装规则：当 `assets/fonts/optional/` 下存在 `.ttf` / `.otf` 时，
#    随构建拷入 App Bundle 的 `Contents/Resources/fonts/`。
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "${SRCROOT}/.." && pwd)"
export PODS_TARGET_SRCROOT="$REPO_ROOT"
export PODS_CONFIGURATION_BUILD_DIR="${TARGET_TEMP_DIR}/cargokit_out"
export PODS_ROOT="${PODS_ROOT:-${SRCROOT}/Pods}"
export PRODUCT_NAME="acp_bridge"

mkdir -p "$PODS_CONFIGURATION_BUILD_DIR"

sh "$REPO_ROOT/cargokit/build_pod.sh" rust/bridge acp_bridge

DYLIB_SRC="$PODS_CONFIGURATION_BUILD_DIR/acp_bridge/libacp_bridge.dylib"
if [ ! -f "$DYLIB_SRC" ]; then
  echo "error: cargokit did not produce $DYLIB_SRC" >&2
  exit 1
fi

FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "$FRAMEWORKS_DIR"
cp -f "$DYLIB_SRC" "$FRAMEWORKS_DIR/libacp_bridge.dylib"
chmod 755 "$FRAMEWORKS_DIR/libacp_bridge.dylib"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] || [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  /usr/bin/codesign --force --sign "$SIGN_ID" --timestamp=none "$FRAMEWORKS_DIR/libacp_bridge.dylib"
fi

# 可选字体（对齐 windows/CMakeLists.txt）：assets/fonts/optional/*.ttf|*.otf 存在时拷入 Contents/Resources/fonts/。
OPT_FONTS_DIR="$REPO_ROOT/assets/fonts/optional"
if [ -d "$OPT_FONTS_DIR" ]; then
  shopt -s nullglob nocaseglob
  FONT_FILES=("$OPT_FONTS_DIR"/*.ttf "$OPT_FONTS_DIR"/*.otf)
  shopt -u nullglob nocaseglob
  if [ "${#FONT_FILES[@]}" -gt 0 ]; then
    DEST_FONTS_DIR="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/fonts"
    mkdir -p "$DEST_FONTS_DIR"
    cp -f "${FONT_FILES[@]}" "$DEST_FONTS_DIR/"
    echo "Bundled ${#FONT_FILES[@]} optional font(s) into $DEST_FONTS_DIR"
  fi
fi
