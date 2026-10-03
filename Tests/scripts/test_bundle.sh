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

IME_PATH='build/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app'

rebuild_bundle() {
    rm -rf build/KeyHue.app
    scripts/build-app.sh >/dev/null 2>&1
}

test_bundle_rejects_outer_app_identity_executable_and_version_mismatch() {
    make_bundle_repo
    scripts/build-app.sh
    VERSION=9.8.8 expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '번들 버전 불일치'
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier another.app' build/KeyHue.app/Contents/Info.plist
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '번들 ID 불일치'
    rebuild_bundle
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Other' build/KeyHue.app/Contents/Info.plist
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '실행 파일 이름 불일치'
    rebuild_bundle
    rm build/KeyHue.app/Contents/MacOS/KeyHue
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '실행 파일이 없습니다'
}

test_bundle_rejects_latin_mode_enabled_by_default_or_missing_default_state() {
    make_bundle_repo
    scripts/build-app.sh
    local modes='ComponentInputModeDict:tsInputModeListKey:io.github.sejoung.keyhue.inputmethod.spike'
    /usr/libexec/PlistBuddy -c "Set :$modes.Latin:tsInputModeDefaultStateKey true" "$IME_PATH/Contents/Info.plist"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '입력 모드는 명시적으로 활성화해야 합니다 (Latin)'
    rebuild_bundle
    # 키가 없으면 macOS 기본값(활성)이 되므로 거부해야 한다
    /usr/libexec/PlistBuddy -c "Delete :$modes.Hangul:tsInputModeDefaultStateKey" "$IME_PATH/Contents/Info.plist"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '입력 모드는 명시적으로 활성화해야 합니다 (Hangul)'
}

test_bundle_rejects_wrong_imk_server_metadata() {
    make_bundle_repo
    local key value message
    for key in LSBackgroundOnly:false:'IMK는 백그라운드 앱이어야' \
               InputMethodServerControllerClass:OtherController:'IMK 컨트롤러 클래스 불일치' \
               InputMethodConnectionName:Other_Connection:'IMK 연결 이름 불일치' \
               tsInputMethodIconFileKey:AppIcon.icns:'입력기 설정 아이콘 불일치'; do
        value="${key#*:}"; message="${value#*:}"; value="${value%%:*}"; key="${key%%:*}"
        rebuild_bundle
        /usr/libexec/PlistBuddy -c "Set :$key $value" "$IME_PATH/Contents/Info.plist"
        expect_failure scripts/check-bundle.sh
        assert_contains "$OUT" "$message"
    done
}

test_bundle_rejects_missing_model_license_or_model_inside_service() {
    make_bundle_repo
    scripts/build-app.sh
    rm build/KeyHue.app/Contents/Resources/Mistype/LICENSE
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '판정 모델 라이선스 누락'
    rebuild_bundle
    cp -R build/KeyHue.app/Contents/Resources/Mistype "$IME_PATH/Contents/Resources/"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '판정 모델을 포함하지 않습니다'
}

test_bundle_rejects_missing_app_localization_or_service_icon() {
    make_bundle_repo
    scripts/build-app.sh
    rm build/KeyHue.app/Contents/Resources/ja.lproj/Localizable.strings
    expect_failure scripts/check-bundle.sh
    rebuild_bundle
    rm "$IME_PATH/Contents/Resources/InputMethodIcon.png"
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" '입력기 설정 아이콘 누락'
}

test_bundle_fails_when_service_self_check_fails() {
    make_bundle_repo
    scripts/build-app.sh
    printf '#!/bin/sh\necho "self-check called: $*"\nexit 3\n' > "$IME_PATH/Contents/MacOS/KeyHueInputMethodSpike"
    codesign --force --sign - "$IME_PATH" >/dev/null 2>&1
    codesign --force --sign - build/KeyHue.app >/dev/null 2>&1
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" 'self-check called: --self-check'
    assert_not_contains "$OUT" 'bundle verified: KeyHue '
}

test_bundle_universal_check_rejects_single_architecture() {
    make_bundle_repo
    scripts/build-app.sh
    printf '#!/bin/sh\necho arm64\n' > bin/lipo
    UNIVERSAL=1 expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" 'universal binary가 아닙니다 (arm64)'
    UNIVERSAL=0 expect_success scripts/check-bundle.sh
}

test_bundle_accepts_path_with_spaces_and_rejects_tampered_outer_app() {
    make_bundle_repo
    scripts/build-app.sh
    mkdir -p "$TEST_TMP/My Apps"
    ditto build/KeyHue.app "$TEST_TMP/My Apps/KeyHue.app"
    KEYHUE_APP_PATH="$TEST_TMP/My Apps/KeyHue.app" expect_success scripts/check-bundle.sh
    echo tampered >> "$TEST_TMP/My Apps/KeyHue.app/Contents/Resources/Mistype/LICENSE"
    KEYHUE_APP_PATH="$TEST_TMP/My Apps/KeyHue.app" expect_failure scripts/check-bundle.sh
    assert_not_contains "$OUT" 'bundle verified: KeyHue '
}

test_bundle_check_without_version_file_fails() {
    make_bundle_repo
    scripts/build-app.sh
    rm VERSION
    expect_failure scripts/check-bundle.sh
    assert_contains "$OUT" 'VERSION'
    assert_not_contains "$OUT" 'bundle verified'
}

test_package_refuses_certificate_identity_that_produced_adhoc_signature() {
    make_bundle_repo
    # 가짜 build-app.sh는 항상 ad-hoc으로 서명한다(키체인에 인증서가 없는 것과 같다)
    CODESIGN_IDENTITY="KeyHue Development" expect_failure scripts/package.sh
    assert_contains "$OUT" "'KeyHue Development'로 서명하지 못했습니다"
    [[ ! -e build/dist/KeyHue-9.8.7.zip && ! -e build/dist/KeyHue.zip ]] || fail "서명 실패 후 배포물을 만들었습니다"
}

test_package_checksum_verifies_and_stable_name_replaces_old_zip() {
    make_bundle_repo
    mkdir -p build/dist
    echo "old release" > build/dist/KeyHue.zip
    expect_success scripts/package.sh
    (cd build/dist && shasum -a 256 -c KeyHue-9.8.7.zip.sha256 >/dev/null) || fail "SHA-256 파일이 맞지 않습니다"
    cmp -s build/dist/KeyHue.zip build/dist/KeyHue-9.8.7.zip || fail "KeyHue.zip이 새 버전과 다릅니다"
    assert_contains "$OUT" "$(cat build/dist/KeyHue-9.8.7.zip.sha256)"
}

# build-app.sh·notarize.sh는 실제 swift build 전에 입력을 거부해야 한다. 가짜 swift/build-app으로 확인한다.
make_build_guard_repo() {
    mkdir -p scripts bin
    cp "$REPO_ROOT/scripts/"{app-config,build-app,notarize}.sh scripts/
    echo 9.8.7 > VERSION
    printf '#!/bin/sh\necho "swift $*" >> "$TEST_TMP/tool-calls"\nexit 1\n' > bin/swift
    printf '#!/bin/sh\necho "build-app" >> "$TEST_TMP/tool-calls"\nexit 1\n' > scripts/fake-build-app.sh
    chmod +x scripts/*.sh bin/swift
    export PATH="$PWD/bin:$PATH"
    unset VERSION BUILD_NUMBER CODESIGN_IDENTITY
}

test_build_app_rejects_bad_build_number_or_version_before_building() {
    make_build_guard_repo
    for number in 12a -1 1.5 ' '; do
        BUILD_NUMBER="$number" expect_failure scripts/build-app.sh
        assert_contains "$OUT" 'BUILD_NUMBER는 정수여야 합니다'
    done
    for version in 1.2 01.3.0 0.02.0 1.2.03; do
        VERSION="$version" expect_failure scripts/build-app.sh
        assert_contains "$OUT" 'X.Y.Z'
    done
    [[ ! -e "$TEST_TMP/tool-calls" ]] || fail "검증 전에 빌드했습니다: $(cat "$TEST_TMP/tool-calls")"
}

test_notarize_requires_developer_identity_before_building() {
    make_build_guard_repo
    mv scripts/fake-build-app.sh scripts/build-app.sh
    expect_failure scripts/notarize.sh
    assert_contains "$OUT" 'Developer ID Application 인증서 이름이 필요합니다'
    CODESIGN_IDENTITY=- expect_failure scripts/notarize.sh
    assert_contains "$OUT" 'ad-hoc 서명(-)으로는 배포할 수 없습니다'
    [[ ! -e "$TEST_TMP/tool-calls" ]] || fail "검증 전에 빌드했습니다"
}

test_signing_identity_prefers_explicit_then_exact_development_certificate() {
    mkdir -p bin
    cat > bin/security <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$TEST_TMP/security.log"
[[ -n "${FAKE_IDENTITIES:-}" ]] && printf '%s\n' "$FAKE_IDENTITIES"
exit 0
STUB
    chmod +x bin/security
    export PATH="$PWD/bin:$PATH" VERSION=1.2.3
    unset CODESIGN_IDENTITY
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/app-config.sh"
    assert_eq "$(signing_identity)" "-" "인증서가 없으면 ad-hoc"
    export FAKE_IDENTITIES='  1) AAAA "KeyHue Development Old"
  2) BBBB "KeyHue Development"
     2 identities found'
    assert_eq "$(signing_identity)" "BBBB" "이름이 정확히 같은 인증서의 해시"
    assert_eq "$(CODESIGN_IDENTITY="KeyHue Development" signing_identity)" "BBBB" "이름 대신 해시로 서명"
    assert_eq "$(CODESIGN_IDENTITY="Developer ID Application: A (TEAM)" signing_identity)" "Developer ID Application: A (TEAM)"
    assert_eq "$(CODESIGN_IDENTITY=- signing_identity)" "-"
}
