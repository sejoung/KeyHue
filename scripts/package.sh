#!/usr/bin/env bash
# 배포용 zip을 만든다: universal(arm64 + x86_64) .app → zip + SHA-256.
# GitHub Actions 릴리즈 workflow(.github/workflows/release.yml)가 쓰고, 로컬에서도 같은 결과를 만든다.
#
#   scripts/package.sh                 # ad-hoc 서명 (Apple Developer 계정 없이)
# 입력기 서비스를 포함한 KeyHue ZIP 하나를 만든다.
#   CODESIGN_IDENTITY="…" scripts/package.sh
#
# 결과: build/dist/KeyHue-<VERSION>.zip, .sha256, 그리고 같은 파일의 고정 이름 사본 KeyHue.zip
#       (다운로드 페이지는 releases/latest/download/KeyHue.zip로 항상 최신 버전을 받는다)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

(( $# == 0 )) || { echo "usage: scripts/package.sh (KeyHue 하나만 배포합니다)" >&2; exit 64; }
# shellcheck source=scripts/app-config.sh
source scripts/app-config.sh
DIST=build/dist
ZIP="$DIST/$PRODUCT-$VERSION.zip"

UNIVERSAL=1 VERSION="$VERSION" scripts/build-app.sh

echo "==> check bundle"
UNIVERSAL=1 VERSION="$VERSION" scripts/check-bundle.sh
# 서명 요구 조건: 고정 인증서면 "certificate leaf", ad-hoc이면 "cdhash" (ADR 0021)
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | grep designated || true)"
echo "    ${REQUIREMENT# }"
if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" && "$REQUIREMENT" != *"certificate leaf"* ]]; then
    echo "error: '$CODESIGN_IDENTITY'로 서명하지 못했습니다" >&2
    exit 1
fi

echo "==> zip"
mkdir -p "$DIST"
# ditto: 확장 속성과 심볼릭 링크를 보존하는 macOS 표준 방식(Finder 압축과 동일)
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
cp "$ZIP" "$DIST/KeyHue.zip"
cat "$ZIP.sha256"
echo "==> $ZIP"
