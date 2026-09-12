#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS_DIR="$ROOT_DIR/.build/Products"
INTERMEDIATES_DIR="$ROOT_DIR/.build/Intermediates"
DIST_DIR="$ROOT_DIR/dist"
APP="$PRODUCTS_DIR/Release-iphoneos/NMEAPad.app"
BINARY="$APP/NMEAPad"

command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found" >&2; exit 1; }
command -v ldid >/dev/null || { echo "error: ldid not found (brew install ldid)" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

cd "$ROOT_DIR"
xcodegen generate
xcodebuild \
  -project "$ROOT_DIR/NMEAPad.xcodeproj" \
  -target NMEAPad \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) DEBUG=1' \
  SUPPORTED_PLATFORMS=iphoneos \
  SYMROOT="$PRODUCTS_DIR" \
  OBJROOT="$INTERMEDIATES_DIR" \
  build

test -f "$BINARY" || { echo "error: app binary not found at $BINARY" >&2; exit 1; }
ldid -S"$ROOT_DIR/NMEAPad/NMEAPad.entitlements" "$BINARY"

STAGE_DIR="$(mktemp -d /tmp/nmeapad-ipa.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$STAGE_DIR/Payload" "$DIST_DIR"
cp -R "$APP" "$STAGE_DIR/Payload/NMEAPad.app"
rm -f "$DIST_DIR/NMEAPad.ipa"
(cd "$STAGE_DIR" && zip -qry "$DIST_DIR/NMEAPad.ipa" Payload)

shasum -a 256 "$DIST_DIR/NMEAPad.ipa" > "$DIST_DIR/NMEAPad.ipa.sha256"
echo "Built: $DIST_DIR/NMEAPad.ipa"
ldid -e "$BINARY"
