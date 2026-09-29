#!/usr/bin/env bash
# KeyHue.app 번들을 만든다. (SwiftPM 빌드 + Info.plist + AppIcon.icns + 메뉴바 아이콘 + 번역 + codesign)
#
#   scripts/build-app.sh                 # release, ad-hoc 서명 → build/KeyHue.app
#   CONFIG=debug scripts/build-app.sh
#   UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
# 버전의 원본은 저장소 루트의 VERSION 파일이다(scripts/release.sh가 올린다).
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${CODESIGN_IDENTITY:--}"
OUT="$ROOT/build"
APP="$OUT/KeyHue.app"
WORK="$OUT/work"

cd "$ROOT"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product KeyHue "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}")"

echo "==> app icon"
mkdir -p "$WORK"
swift scripts/make-icon.swift docs/icon.png "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"
swift scripts/make-menubar-icon.swift docs/icon.png "$WORK/MenuBarIcon"

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KeyHue" "$APP/Contents/MacOS/KeyHue"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$WORK/MenuBarIcon/"MenuBarIcon*.png "$APP/Contents/Resources/"
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
    plutil -lint "$APP/Contents/Resources/$(basename "$lproj")/Localizable.strings" >/dev/null
done
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> codesign ($IDENTITY)"
# 실제 인증서(Developer ID 등)는 notarization에 필요한 보안 타임스탬프를 붙인다.
TIMESTAMP="--timestamp"
[[ "$IDENTITY" == "-" ]] && TIMESTAMP="--timestamp=none"
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> $APP"
