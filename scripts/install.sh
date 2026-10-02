#!/usr/bin/env bash
# 내장 입력기를 포함한 KeyHue.app을 설치하고 다시 실행한다. 입력기 설치/제거는 앱이 담당한다.
#
#   scripts/install.sh               # release 빌드 후 설치
#   scripts/install.sh --no-build    # build/KeyHue.app을 그대로 설치
#   INSTALL_DIR=~/Applications scripts/install.sh
#
# 스크립트 테스트용: KEYHUE_APP_SRC(설치할 앱), KEYHUE_SKIP_QUIT=1, KEYHUE_SKIP_LAUNCH=1
#
# build/와 /Applications에 서명이 다른 KeyHue가 함께 있으면, macOS가 "다시 열기" 등에서
# 설치된 쪽을 실행해 방금 허용한 권한이 적용되지 않는 일이 생긴다. 그래서 항상 설치본 하나만 실행한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/app-config.sh
source scripts/app-config.sh
NO_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --no-build)
            (( NO_BUILD == 0 )) || { echo "error: --no-build 중복" >&2; exit 64; }
            NO_BUILD=1
            ;;
        *) echo "usage: scripts/install.sh [--no-build] (입력기는 앱에서 관리합니다)" >&2; exit 64 ;;
    esac
done
SRC="${KEYHUE_APP_SRC:-$APP}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

if (( NO_BUILD == 0 )); then
    scripts/build-app.sh
fi
[[ -d "$SRC" ]] || { echo "error: ${SRC}가 없습니다. scripts/build-app.sh를 먼저 실행하세요" >&2; exit 1; }
codesign --verify --deep --strict "$SRC"
SOURCE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")"
SOURCE_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SRC/Contents/Info.plist")"
[[ "$SOURCE_ID" == "$BUNDLE_ID" && "$SOURCE_EXEC" == "$PRODUCT" ]] || {
    echo "error: 설치 대상의 번들 ID·실행 파일이 $PRODUCT 구성 요소와 다릅니다" >&2; exit 1;
}
IME="$SRC/$EMBEDDED_APP"
[[ -x "$IME/Contents/MacOS/$INPUT_METHOD_PRODUCT" ]] || { echo "error: 내장 입력기 누락" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$IME/Contents/Info.plist")" == "$INPUT_METHOD_BUNDLE_ID" ]] || { echo "error: 내장 입력기 ID 불일치" >&2; exit 1; }
for key in CFBundleShortVersionString CFBundleVersion; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$SRC/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c "Print :$key" "$IME/Contents/Info.plist")" ]] || { echo "error: 내장 입력기 버전/빌드 불일치" >&2; exit 1; }
done
SRC="$(cd "$SRC" && pwd -P)"
[[ -w "$INSTALL_DIR" ]] || { echo "error: ${INSTALL_DIR}에 쓸 수 없습니다 (INSTALL_DIR=~/Applications 로 바꿀 수 있습니다)" >&2; exit 1; }
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
DEST="$INSTALL_DIR/$PRODUCT.app"
[[ "$SRC" != "$DEST" && "$SRC" != "$DEST/"* && "$DEST" != "$SRC/"* ]] || {
    echo "error: 원본과 설치 경로가 겹칩니다" >&2; exit 1;
}
[[ ! -L "$DEST" && ( ! -e "$DEST" || -d "$DEST" ) ]] || { echo "error: 설치 경로가 앱 폴더가 아닙니다" >&2; exit 1; }
REQUIREMENT="$(codesign -d -r- "$SRC" 2>&1 | grep designated || true)"
if [[ "$REQUIREMENT" != *"certificate leaf"* ]]; then
    echo "warning: ad-hoc 서명 빌드입니다. 설치할 때마다 입력 모니터링·손쉬운 사용 권한이 풀립니다."
    echo "         scripts/signing.sh create (또는 install)로 서명 키를 등록하세요."
fi

# 복사·서명 검사를 먼저 끝내고 기존 설치본은 교체가 성공할 때까지 보관한다.
STAGING="$(mktemp -d "$INSTALL_DIR/.keyhue-install.XXXXXX")"
STAGED_APP="$STAGING/$PRODUCT.app"
PREVIOUS_APP="$STAGING/previous.app"
MOVED_NEW=0
COMMITTED=0
cleanup() {
    if (( COMMITTED == 0 )); then
        if [[ -d "$PREVIOUS_APP" ]]; then
            rm -rf "$DEST"
            mv "$PREVIOUS_APP" "$DEST"
        elif (( MOVED_NEW == 1 )); then
            rm -rf "$DEST"
        fi
    fi
    if [[ ! -e "$PREVIOUS_APP" ]]; then rm -rf "$STAGING"; else echo "error: 복구할 백업이 남아 있습니다: $PREVIOUS_APP" >&2; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$SRC" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

echo "==> 실행 중인 $PRODUCT 종료"
if [[ -n "${KEYHUE_SKIP_QUIT:-}" ]]; then
    echo "    (건너뜀)"
elif pgrep -f "KeyHue.app/Contents/MacOS/KeyHue" >/dev/null; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "KeyHue.app/Contents/MacOS/KeyHue" >/dev/null || break
        sleep 0.5
    done
    pkill -f "KeyHue.app/Contents/MacOS/KeyHue" 2>/dev/null || true
fi

echo "==> 설치: $DEST"
if [[ -d "$DEST" ]]; then mv "$DEST" "$PREVIOUS_APP"; fi
mv "$STAGED_APP" "$DEST"
MOVED_NEW=1
codesign --verify --deep --strict "$DEST"
COMMITTED=1
rm -rf "$PREVIOUS_APP"

# 설치본과 build/ 외에 다른 KeyHue가 있으면 알린다(오래된 다운로드 등).
OTHERS="$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null \
    | grep -v -e "^$DEST$" -e "^$ROOT/build/" -e "/\.build/" -e "/\.Trash/" || true)"
if [[ -n "$OTHERS" ]]; then
    echo "warning: 다른 위치에도 KeyHue가 있습니다. 서명이 다르면 권한이 엇갈릴 수 있으니 지우는 것을 권장합니다:"
    echo "$OTHERS" | sed 's/^/         /'
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")"
echo "==> $PRODUCT $VERSION ($BUILD) 설치 완료"
echo "    ${REQUIREMENT# }"
if [[ -n "${KEYHUE_SKIP_LAUNCH:-}" ]]; then
    echo "    (건너뜀)"
else
    open "$DEST"
fi
