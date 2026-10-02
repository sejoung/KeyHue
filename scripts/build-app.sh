#!/usr/bin/env bash
# 입력기 서비스를 포함한 KeyHue.app 하나를 만든다. 내부 서비스부터 서명한다.
# CONFIG=debug, UNIVERSAL=1, CODESIGN_IDENTITY 환경 변수를 지원한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
(( $# == 0 )) || { echo "usage: scripts/build-app.sh (KeyHue 하나만 빌드합니다)" >&2; exit 64; }
# shellcheck source=scripts/app-config.sh
source scripts/app-config.sh
CONFIG="${CONFIG:-release}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "error: BUILD_NUMBER는 정수여야 합니다" >&2; exit 64; }
IDENTITY="$(signing_identity)"
WORK=build/work/app
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" != 1 ]] || ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "==> swift build ($CONFIG)"
for target in "$INPUT_METHOD_PRODUCT" "$PRODUCT"; do
    swift build -c "$CONFIG" --product "$target" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
done
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}")"

echo "==> icons"
mkdir -p "$WORK"
swift scripts/make-icon.swift docs/icon.png "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"
swift scripts/make-menubar-icon.swift docs/icon.png "$WORK/MenuBarIcon"
swift scripts/make-menubar-icon.swift docs/icon.png "$WORK/MenuBarIcon" 64 HUDIcon
swift scripts/make-input-method-icons.swift "$WORK/InputMethodIcons"

echo "==> bundle"
rm -rf "$APP"
IME="$APP/$EMBEDDED_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$IME/Contents/MacOS" "$IME/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "$BIN_DIR/$INPUT_METHOD_PRODUCT" "$IME/Contents/MacOS/$INPUT_METHOD_PRODUCT"
for bundle in "$APP" "$IME"; do cp "$WORK/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"; done
cp "$WORK/MenuBarIcon/"MenuBarIcon*.png "$WORK/MenuBarIcon/"HUDIcon*.png "$APP/Contents/Resources/"
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
    plutil -lint "$APP/Contents/Resources/$(basename "$lproj")/Localizable.strings" >/dev/null
done
cp -R Resources/Mistype "$APP/Contents/Resources/"
cp "$WORK/InputMethodIcons/"*.tiff "$IME/Contents/Resources/"
cp "$WORK/AppIcon.iconset/icon_128x128.png" "$IME/Contents/Resources/InputMethodIcon.png"
cp Resources/InputMethodSpike/README.md "$IME/Contents/Resources/"
cp -R Resources/InputMethodSpike/*.lproj "$IME/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/InputMethodSpike/Info.plist > "$IME/Contents/Info.plist"

echo "==> codesign ($IDENTITY)"
TIMESTAMP="--timestamp=none"
[[ "$IDENTITY" != *"Developer ID"* ]] || TIMESTAMP="--timestamp"
for bundle in "$IME" "$APP"; do
    plutil -lint "$bundle/Contents/Info.plist" >/dev/null
    codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$bundle"
done
VERSION="$VERSION" scripts/check-bundle.sh
echo "==> $APP"
