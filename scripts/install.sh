#!/usr/bin/env bash
# 로컬 빌드를 설치하고 다시 실행한다: 빌드 → 실행 중인 KeyHue 종료 → /Applications 교체 → 실행
#
#   scripts/install.sh               # release 빌드 후 설치
#   scripts/install.sh --no-build    # build/KeyHue.app을 그대로 설치
#   INSTALL_DIR=~/Applications scripts/install.sh
#
# build/와 /Applications에 서명이 다른 KeyHue가 함께 있으면, macOS가 "다시 열기" 등에서
# 설치된 쪽을 실행해 방금 허용한 권한이 적용되지 않는 일이 생긴다. 그래서 항상 설치본 하나만 실행한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="io.github.sejoung.keyhue"
SRC="build/KeyHue.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/KeyHue.app"

if [[ "${1:-}" != "--no-build" ]]; then
    scripts/build-app.sh
fi
[[ -d "$SRC" ]] || { echo "error: ${SRC}가 없습니다. scripts/build-app.sh를 먼저 실행하세요" >&2; exit 1; }
[[ -w "$INSTALL_DIR" ]] || { echo "error: ${INSTALL_DIR}에 쓸 수 없습니다 (INSTALL_DIR=~/Applications 로 바꿀 수 있습니다)" >&2; exit 1; }

REQUIREMENT="$(codesign -d -r- "$SRC" 2>&1 | grep designated || true)"
if [[ "$REQUIREMENT" != *"certificate leaf"* ]]; then
    echo "warning: ad-hoc 서명 빌드입니다. 설치할 때마다 입력 모니터링·손쉬운 사용 권한이 풀립니다."
    echo "         scripts/signing.sh create (또는 install)로 서명 키를 등록하세요."
fi

echo "==> 실행 중인 KeyHue 종료"
if pgrep -f "KeyHue.app/Contents/MacOS/KeyHue" >/dev/null; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "KeyHue.app/Contents/MacOS/KeyHue" >/dev/null || break
        sleep 0.5
    done
    pkill -f "KeyHue.app/Contents/MacOS/KeyHue" 2>/dev/null || true
fi

echo "==> 설치: $DEST"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
codesign --verify --strict "$DEST"

# 설치본과 build/ 외에 다른 KeyHue가 있으면 알린다(오래된 다운로드 등).
OTHERS="$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null \
    | grep -v -e "^$DEST$" -e "^$ROOT/build/" -e "/\.build/" -e "/\.Trash/" || true)"
if [[ -n "$OTHERS" ]]; then
    echo "warning: 다른 위치에도 KeyHue가 있습니다. 서명이 다르면 권한이 엇갈릴 수 있으니 지우는 것을 권장합니다:"
    echo "$OTHERS" | sed 's/^/         /'
fi

echo "==> 실행"
open "$DEST"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")"
echo "==> KeyHue $VERSION ($BUILD) 설치 완료"
echo "    ${REQUIREMENT# }"
