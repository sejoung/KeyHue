#!/usr/bin/env bash
# 배포용 바이너리를 만든다: universal 빌드 → Developer ID 서명 → notarization → staple → zip
# 버전은 VERSION 파일을 쓴다. 보통 scripts/release.sh로 태그를 만든 뒤 그 태그를 체크아웃해서 실행한다.
#
#   CODESIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)" \
#   NOTARY_PROFILE=keyhue-notary \
#   scripts/notarize.sh
#
# 사전 준비(최초 1회):
#   xcrun notarytool store-credentials keyhue-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
#
# SKIP_NOTARIZE=1 이면 서명까지만 한다(인증서/notary 설정 점검용).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${CODESIGN_IDENTITY:?Developer ID Application 인증서 이름이 필요합니다 (security find-identity -v -p codesigning)}"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "error: ad-hoc 서명(-)으로는 배포할 수 없습니다" >&2
    exit 1
fi
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
APP="build/KeyHue.app"
ZIP="build/KeyHue-$VERSION.zip"

UNIVERSAL=1 VERSION="$VERSION" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" scripts/build-app.sh

echo "==> verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Runtime" || {
    echo "error: Developer ID 서명이 아니거나 hardened runtime이 꺼져 있습니다" >&2
    exit 1
}

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> notarization skipped: $ZIP"
    exit 0
fi

: "${NOTARY_PROFILE:?notarytool keychain profile 이름이 필요합니다 (xcrun notarytool store-credentials)}"

echo "==> notarize ($NOTARY_PROFILE)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# staple된 앱으로 zip을 다시 만든다.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "==> $ZIP"
