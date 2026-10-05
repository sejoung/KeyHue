#!/usr/bin/env bash
# 서명과 선택한 앱의 ID·실행 파일·버전·리소스를 검증한다. UNIVERSAL=1이면 두 아키텍처도 검사한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
(( $# == 0 )) || { echo "usage: scripts/check-bundle.sh (내장 입력기를 포함한 KeyHue만 검사합니다)" >&2; exit 64; }
# shellcheck source=scripts/app-config.sh
source scripts/app-config.sh
APP="${KEYHUE_APP_PATH:-$APP}"

check_bundle() {
    local COMPONENT_APP="$1" COMPONENT_PRODUCT="$2" COMPONENT_BUNDLE_ID="$3"
    local plist mode mode_key icon language names embedded archs key
    plist="$COMPONENT_APP/Contents/Info.plist"
    plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
    [[ -x "$COMPONENT_APP/Contents/MacOS/$COMPONENT_PRODUCT" ]] || { echo "error: 실행 파일이 없습니다" >&2; exit 1; }
    plutil -lint "$plist" >/dev/null
    [[ "$(plist_value CFBundleIdentifier)" == "$COMPONENT_BUNDLE_ID" ]] || { echo "error: 번들 ID 불일치" >&2; exit 1; }
    [[ "$(plist_value CFBundleExecutable)" == "$COMPONENT_PRODUCT" ]] || { echo "error: 실행 파일 이름 불일치" >&2; exit 1; }
    [[ "$(plist_value CFBundleShortVersionString)" == "$VERSION" ]] || { echo "error: 번들 버전 불일치" >&2; exit 1; }
    [[ -f "$COMPONENT_APP/Contents/Resources/AppIcon.icns" ]] || { echo "error: 앱 아이콘 누락" >&2; exit 1; }

    if [[ "$COMPONENT_PRODUCT" == "$INPUT_METHOD_PRODUCT" ]]; then
        [[ "$(plist_value LSBackgroundOnly)" == true ]] || { echo "error: IMK는 백그라운드 앱이어야 합니다" >&2; exit 1; }
        [[ "$(plist_value InputMethodServerControllerClass)" == KeyHueSpikeInputController ]] || { echo "error: IMK 컨트롤러 클래스 불일치" >&2; exit 1; }
        [[ "$(plist_value InputMethodConnectionName)" == KeyHueInputMethodSpike_Connection ]] || { echo "error: IMK 연결 이름 불일치" >&2; exit 1; }
        [[ "$(plist_value tsInputMethodIconFileKey)" == InputMethodIcon.png ]] || { echo "error: 입력기 설정 아이콘 불일치" >&2; exit 1; }
        [[ -s "$COMPONENT_APP/Contents/Resources/InputMethodIcon.png" ]] || { echo "error: 입력기 설정 아이콘 누락" >&2; exit 1; }
        for mode in Hangul Latin; do
            mode_key="ComponentInputModeDict:tsInputModeListKey:$COMPONENT_BUNDLE_ID.$mode"
            [[ "$(plist_value "$mode_key:tsInputModeDefaultStateKey")" == false ]] || { echo "error: 입력 모드는 명시적으로 활성화해야 합니다 ($mode)" >&2; exit 1; }
            [[ "$(plist_value "$mode_key:tsInputModeMenuIconFileKey")" == "${mode}Template.tiff" &&
               "$(plist_value "$mode_key:tsInputModeAlternateMenuIconFileKey")" == "${mode}Alternate.tiff" ]] || { echo "error: 입력 모드 아이콘 불일치 ($mode)" >&2; exit 1; }
            [[ "$(plist_value "$mode_key:tsInputModePaletteIconFileKey")" == "${mode}Palette.tiff" ]] || { echo "error: 입력 모드 설정 아이콘 불일치 ($mode)" >&2; exit 1; }
            for icon in "${mode}Template.tiff" "${mode}Alternate.tiff" "${mode}Palette.tiff"; do
                [[ -s "$COMPONENT_APP/Contents/Resources/$icon" ]] || { echo "error: 입력 모드 아이콘 누락 ($icon)" >&2; exit 1; }
            done
        done
        for language in en ko; do
            names="$COMPONENT_APP/Contents/Resources/$language.lproj/InfoPlist.strings"
            plutil -lint "$names" >/dev/null
            for key in CFBundleName CFBundleDisplayName "$COMPONENT_BUNDLE_ID" "$COMPONENT_BUNDLE_ID.Hangul" "$COMPONENT_BUNDLE_ID.Latin"; do
                [[ -n "$(/usr/libexec/PlistBuddy -c "Print :$key" "$names")" ]] || { echo "error: 입력기 표시 이름 누락 ($language, $key)" >&2; exit 1; }
            done
        done
        # 고침 판정(ADR 0064): 설치본은 앱 밖에서 실행되므로 모델과 라이선스를 직접 가진다.
        [[ -s "$COMPONENT_APP/Contents/Resources/Mistype/hangul-syllables.tsv" ]] || { echo "error: 입력기 판정 모델 누락" >&2; exit 1; }
        [[ -f "$COMPONENT_APP/Contents/Resources/Mistype/LICENSE" ]] || { echo "error: 입력기 판정 모델 라이선스 누락" >&2; exit 1; }
    else
        for language in en ko ja; do
            plutil -lint "$COMPONENT_APP/Contents/Resources/$language.lproj/Localizable.strings" >/dev/null
        done
        embedded="$COMPONENT_APP/$EMBEDDED_APP"
        [[ -d "$embedded" ]] || { echo "error: 내장 입력기 누락" >&2; exit 1; }
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$embedded/Contents/Info.plist")" == "$(plist_value CFBundleVersion)" ]] || { echo "error: 내장 입력기 빌드 번호 불일치" >&2; exit 1; }
        check_bundle "$embedded" "$INPUT_METHOD_PRODUCT" "$INPUT_METHOD_BUNDLE_ID"
        "$embedded/Contents/MacOS/KeyHueInputMethodSpike" --self-check
        [[ -f "$COMPONENT_APP/Contents/Resources/Mistype/LICENSE" ]] || { echo "error: 판정 모델 라이선스 누락" >&2; exit 1; }
    fi
    if [[ "${UNIVERSAL:-0}" == 1 ]]; then
        archs="$(lipo -archs "$COMPONENT_APP/Contents/MacOS/$COMPONENT_PRODUCT")"
        [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "error: universal binary가 아닙니다 ($archs)" >&2; exit 1; }
    fi
    codesign --verify --deep --strict "$COMPONENT_APP"
    echo "==> bundle verified: $COMPONENT_PRODUCT $VERSION"
}
check_bundle "$APP" "$PRODUCT" "$BUNDLE_ID"
