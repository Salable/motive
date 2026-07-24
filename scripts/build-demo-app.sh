#!/bin/zsh
# Build dist/MotiveDemo.app (and optionally a portable zip).
#
#   scripts/build-demo-app.sh                build the app bundle (host arch)
#   scripts/build-demo-app.sh --universal    arm64 + x86_64 slices
#   scripts/build-demo-app.sh --zip          also produce dist/MotiveDemo-<version>.zip
#
# Signing: ad-hoc by default (fine locally; downloaders right-click → Open, or
# `xattr -cr MotiveDemo.app`). Set MOTIVE_SIGN_IDENTITY to a Developer ID for
# distribution-grade signing.
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/MotiveDemo.app"
CONTENTS_DIR="$APP_DIR/Contents"

UNIVERSAL=0
MAKE_ZIP=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --zip) MAKE_ZIP=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

cd "$PROJECT_DIR"

if [[ $UNIVERSAL -eq 1 ]]; then
  swift build -c release --arch arm64 --arch x86_64
  PRODUCTS="$PROJECT_DIR/.build/apple/Products/Release"
else
  swift build -c release
  PRODUCTS="$PROJECT_DIR/.build/release"
fi

if [[ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
  python3 "$SCRIPT_DIR/make-icon.py"
fi

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$PRODUCTS/motive-demo" "$CONTENTS_DIR/MacOS/MotiveDemo"
# Ship the MCP shim inside the bundle so users can point Claude Desktop at it.
cp "$PRODUCTS/motive-mcp" "$CONTENTS_DIR/MacOS/motive-mcp"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
# Embedded sprite: the demo finds it via Bundle.main resources.
cp -R "$PROJECT_DIR/Sprites/salli" "$CONTENTS_DIR/Resources/salli"
chmod +x "$CONTENTS_DIR/MacOS/MotiveDemo" "$CONTENTS_DIR/MacOS/motive-mcp"

IDENTITY="${MOTIVE_SIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
fi

if [[ $MAKE_ZIP -eq 1 ]]; then
  VERSION=$(grep -o 'current = "[^"]*"' "$PROJECT_DIR/Sources/MotiveCore/MotiveVersion.swift" | cut -d'"' -f2)
  ZIP="$DIST_DIR/MotiveDemo-$VERSION.zip"
  rm -f "$ZIP"
  (cd "$DIST_DIR" && ditto -c -k --keepParent MotiveDemo.app "$(basename "$ZIP")")
  echo "$ZIP"
fi

echo "$APP_DIR"
