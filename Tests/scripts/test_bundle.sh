# 통합 앱의 내부 구조를 실제 서명·압축 도구로 검사한다. 실제 입력기는 실행하지 않는다.
make_bundle_repo() {
    mkdir -p scripts bin
    cp "$REPO_ROOT/scripts/"{app-config,package,check-bundle}.sh scripts/
    echo 9.8.7 > VERSION
    cat > scripts/build-app.sh <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
source scripts/app-config.sh
source "$REPO_ROOT/Tests/scripts/lib.sh"
make_packaged_app "$APP" "$VERSION"
TOOL
    cat > bin/lipo <<'TOOL'
#!/usr/bin/env bash
echo "$*" >> "$TEST_TMP/lipo-arguments"
echo 'arm64 x86_64'
TOOL
    chmod +x scripts/*.sh bin/lipo
    export PATH="$PWD/bin:$PATH" CODESIGN_IDENTITY=-
    unset VERSION
}

test_all_public_scripts_reject_component_arguments_before_building() {
    for script in build-app check-bundle install package notarize; do
        expect_failure "$REPO_ROOT/scripts/$script.sh" input-method-spike
        assert_contains "$OUT" 'usage:'
        expect_failure "$REPO_ROOT/scripts/$script.sh" utility
        assert_contains "$OUT" 'usage:'
    done
}

test_package_contains_one_app_with_same_version_and_both_architecture_checks() {
    make_bundle_repo
    mkdir -p build/dist
    echo keep > build/dist/notes.md
    expect_success scripts/package.sh
    assert_contains "$(unzip -Z1 build/dist/KeyHue.zip)" 'KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike'
    assert_contains "$(cat "$TEST_TMP/lipo-arguments")" 'KeyHue.app/Contents/MacOS/KeyHue'
    assert_contains "$(cat "$TEST_TMP/lipo-arguments")" 'KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike'
    [[ -f build/dist/KeyHue-9.8.7.zip && -f build/dist/notes.md ]] || fail "배포물/노트 없음"
    local ime='build/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app'
    assert_eq "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ime/Contents/Info.plist")" 9.8.7
}

test_bundle_rejects_missing_payload_or_different_version_and_build() {
    make_bundle_repo
    scripts/build-app.sh
    local ime='build/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app'
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 999' "$ime/Contents/Info.plist"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '빌드 번호 불일치'
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 42' "$ime/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.0.1' "$ime/Contents/Info.plist"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '번들 버전 불일치'
    rm -rf "$ime"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '내장 입력기 누락'
}

test_bundle_rejects_wrong_service_id_missing_mode_and_icons() {
    make_bundle_repo
    scripts/build-app.sh
    local ime='build/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app'
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier wrong.bundle' "$ime/Contents/Info.plist"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '번들 ID 불일치'
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.sejoung.keyhue.inputmethod.spike' "$ime/Contents/Info.plist"
    rm "$ime/Contents/Resources/LatinTemplate.tiff"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '입력 모드 아이콘 누락'
    /usr/libexec/PlistBuddy -c 'Delete :ComponentInputModeDict:tsInputModeListKey:io.github.sejoung.keyhue.inputmethod.spike.Latin' "$ime/Contents/Info.plist"
    expect_failure scripts/check-bundle.sh
}

test_bundle_rejects_wrong_palette_and_missing_localized_names() {
    make_bundle_repo
    scripts/build-app.sh
    local ime='build/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app'
    local mode='ComponentInputModeDict:tsInputModeListKey:io.github.sejoung.keyhue.inputmethod.spike.Hangul:tsInputModePaletteIconFileKey'
    /usr/libexec/PlistBuddy -c "Set :$mode AppIcon.icns" "$ime/Contents/Info.plist"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '입력 모드 설정 아이콘 불일치'
    /usr/libexec/PlistBuddy -c "Set :$mode HangulPalette.tiff" "$ime/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Delete :io.github.sejoung.keyhue.inputmethod.spike' "$ime/Contents/Resources/ko.lproj/InfoPlist.strings"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '입력기 표시 이름 누락'
}

test_bundle_rejects_modes_that_default_to_enabled_after_removal() {
    make_bundle_repo
    scripts/build-app.sh
    local ime='build/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app'
    /usr/libexec/PlistBuddy -c 'Set :ComponentInputModeDict:tsInputModeListKey:io.github.sejoung.keyhue.inputmethod.spike.Hangul:tsInputModeDefaultStateKey true' "$ime/Contents/Info.plist"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '입력 모드는 명시적으로 활성화'
}

test_bundle_accepts_explicit_app_path_and_rejects_invalid_version() {
    make_bundle_repo
    scripts/build-app.sh
    ditto build/KeyHue.app "$TEST_TMP/Installed.app"
    KEYHUE_APP_PATH="$TEST_TMP/Installed.app" expect_success scripts/check-bundle.sh
    VERSION=bad expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" 'X.Y.Z'
}
