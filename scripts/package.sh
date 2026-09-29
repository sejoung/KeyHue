#!/usr/bin/env bash
# 배포용 zip을 만든다: universal(arm64 + x86_64) .app → zip + SHA-256.
# GitHub Actions 릴리즈 workflow(.github/workflows/release.yml)가 쓰고, 로컬에서도 같은 결과를 만든다.
#
#   scripts/package.sh                 # ad-hoc 서명 (Apple Developer 계정 없이)
#   CODESIGN_IDENTITY="…" scripts/package.sh
#
# 결과: build/dist/KeyHue-<VERSION>.zip, build/dist/KeyHue-<VERSION>.zip.sha256
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
APP="build/KeyHue.app"
DIST="build/dist"
ZIP="$DIST/KeyHue-$VERSION.zip"

UNIVERSAL=1 VERSION="$VERSION" scripts/build-app.sh

echo "==> check bundle"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/KeyHue")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "error: universal binary가 아닙니다 ($ARCHS)" >&2; exit 1; }
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || { echo "error: 번들 버전($BUNDLE_VERSION) ≠ $VERSION" >&2; exit 1; }
codesign --verify --strict "$APP"
echo "    archs: $ARCHS, version: $BUNDLE_VERSION"

echo "==> zip"
rm -rf "$DIST"
mkdir -p "$DIST"
# ditto: 확장 속성과 심볼릭 링크를 보존하는 macOS 표준 방식(Finder 압축과 동일)
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
cat "$ZIP.sha256"
echo "==> $ZIP"
