#!/usr/bin/env bash
# source 전용: KeyHue 하나의 빌드·서명·배포 메타데이터. 입력기는 내장 서비스다.
# shellcheck disable=SC2034
PRODUCT=KeyHue
BUNDLE_ID=io.github.sejoung.keyhue
APP=build/KeyHue.app
EMBEDDED_APP=Contents/Helpers/KeyHueInputMethodSpike.app
INPUT_METHOD_PRODUCT=KeyHueInputMethodSpike
INPUT_METHOD_BUNDLE_ID=io.github.sejoung.keyhue.inputmethod.spike
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: VERSION은 X.Y.Z 형식이어야 합니다: $VERSION" >&2; return 64; }

signing_identity() {
    local development_name="KeyHue Development" identity
    if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "$development_name" ]]; then
        echo "$CODESIGN_IDENTITY"
    else
        identity="$(security find-identity -p codesigning 2>/dev/null \
            | awk -v name="\"$development_name\"" 'index($0, name) {print $2; exit}')"
        echo "${identity:--}"
    fi
}
