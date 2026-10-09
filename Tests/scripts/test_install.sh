# scripts/install.sh — 실제 /Applications·입력 소스·실행 중인 앱을 건드리지 않는다.
make_fake_app() {
    export KEYHUE_APP_SRC="$TEST_TMP/Fake/KeyHue.app" KEYHUE_SKIP_QUIT=1 KEYHUE_SKIP_LAUNCH=1
    make_packaged_app "$KEYHUE_APP_SRC"
    mkdir -p "$TEST_TMP/Apps"
    export INSTALL_DIR="$TEST_TMP/Apps"
}

test_installs_integrated_app_into_install_dir_and_warns_about_adhoc() {
    make_fake_app
    expect_success "$REPO_ROOT/scripts/install.sh" --no-build
    [[ -x "$INSTALL_DIR/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike" ]] || fail "내장 입력기가 없음"
    assert_contains "$OUT" 'ad-hoc 서명 빌드입니다'
    assert_contains "$OUT" 'KeyHue 9.9.9 (42) 설치 완료'
}

quarantined() {
    xattr -p com.apple.quarantine "$1" >/dev/null 2>&1
}

test_quarantine_option_marks_every_installed_file_like_a_download() {
    make_fake_app
    expect_success "$REPO_ROOT/scripts/install.sh" --no-build
    quarantined "$INSTALL_DIR/KeyHue.app" && fail "옵션 없이 격리 속성을 붙임"
    expect_success "$REPO_ROOT/scripts/install.sh" --no-build --quarantine
    assert_contains "$OUT" '격리 속성을 붙였습니다'
    local ime="$INSTALL_DIR/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app"
    for path in "$INSTALL_DIR/KeyHue.app" "$ime" "$ime/Contents/MacOS/KeyHueInputMethodSpike" "$ime/Contents/Info.plist"; do
        quarantined "$path" || fail "격리 속성 없음: $path"
    done
    quarantined "$KEYHUE_APP_SRC" && fail "빌드 원본에 격리 속성을 붙임"
    codesign --verify --deep --strict "$INSTALL_DIR/KeyHue.app"
    expect_failure "$REPO_ROOT/scripts/install.sh" --no-build --quarantine --quarantine
    assert_contains "$OUT" '중복'
}

test_replaces_previous_install() {
    make_fake_app
    mkdir -p "$INSTALL_DIR/KeyHue.app/Contents"
    echo stale > "$INSTALL_DIR/KeyHue.app/Contents/stale.txt"
    expect_success "$REPO_ROOT/scripts/install.sh" --no-build
    [[ ! -e "$INSTALL_DIR/KeyHue.app/Contents/stale.txt" ]] || fail "이전 파일 남음"
}

test_refuses_unwritable_install_dir() {
    make_fake_app
    INSTALL_DIR=/System expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" '쓸 수 없습니다'
}

test_missing_build_explains_what_to_do() {
    make_fake_app
    KEYHUE_APP_SRC="$TEST_TMP/nothing/KeyHue.app" expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" 'build-app.sh'
}

test_removed_component_arguments_are_rejected_before_any_install() {
    make_fake_app
    for arg in utility input-method-spike unknown; do
        expect_failure "$REPO_ROOT/scripts/install.sh" "$arg" --no-build
        assert_contains "$OUT" '입력기는 앱에서 관리'
    done
    [[ ! -e "$INSTALL_DIR/KeyHue.app" ]] || fail "잘못된 인자로 설치함"
    expect_failure "$REPO_ROOT/scripts/install.sh" --no-build --no-build
    assert_contains "$OUT" '중복'
}

test_wrong_app_is_rejected_before_replacement() {
    make_fake_app
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier another.app' "$KEYHUE_APP_SRC/Contents/Info.plist"
    codesign --force --sign - "$KEYHUE_APP_SRC" >/dev/null 2>&1
    expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" '구성 요소와 다릅니다'
    [[ ! -e "$INSTALL_DIR/KeyHue.app" ]] || fail "다른 앱을 설치함"
}

test_missing_or_mismatched_embedded_payload_is_rejected() {
    make_fake_app
    local ime="$KEYHUE_APP_SRC/Contents/Helpers/KeyHueInputMethodSpike.app"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0' "$ime/Contents/Info.plist"
    codesign --force --sign - "$ime" >/dev/null 2>&1
    codesign --force --sign - "$KEYHUE_APP_SRC" >/dev/null 2>&1
    expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" '버전/빌드 불일치'
    rm -rf "$ime"
    codesign --force --sign - "$KEYHUE_APP_SRC" >/dev/null 2>&1
    expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" '내장 입력기 누락'
}

test_corrupted_inner_signature_is_rejected_before_replacing_app() {
    make_fake_app
    echo broken >> "$KEYHUE_APP_SRC/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/Info.plist"
    expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    [[ ! -e "$INSTALL_DIR/KeyHue.app" ]] || fail "깨진 내장 서명을 설치함"
}

test_copy_verification_failure_preserves_previous_app() {
    make_fake_app
    ditto "$KEYHUE_APP_SRC" "$INSTALL_DIR/KeyHue.app"
    mkdir -p "$TEST_TMP/bin"
    cat > "$TEST_TMP/bin/ditto" <<'TOOL'
#!/usr/bin/env bash
/usr/bin/ditto "$@" || exit 1
echo corrupt >> "$2/Contents/Info.plist"
TOOL
    chmod +x "$TEST_TMP/bin/ditto"
    PATH="$TEST_TMP/bin:$PATH" expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    codesign --verify --deep --strict "$INSTALL_DIR/KeyHue.app"
}

test_failed_final_verification_restores_previous_app() {
    make_fake_app
    make_packaged_app "$INSTALL_DIR/KeyHue.app" 8.8.8
    mkdir -p "$TEST_TMP/bin"
    cat > "$TEST_TMP/bin/codesign" <<'TOOL'
#!/usr/bin/env bash
if [[ "$*" == "--verify --deep --strict $INSTALL_DIR/KeyHue.app" ]]; then exit 1; fi
exec /usr/bin/codesign "$@"
TOOL
    chmod +x "$TEST_TMP/bin/codesign"
    PATH="$TEST_TMP/bin:$PATH" expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_eq "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_DIR/KeyHue.app/Contents/Info.plist")" 8.8.8
    /usr/bin/codesign --verify --deep --strict "$INSTALL_DIR/KeyHue.app"
}

test_installing_from_destination_or_symlink_is_rejected() {
    make_fake_app
    INSTALL_DIR="$TEST_TMP/Fake" expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" '경로가 겹칩니다'
    ln -s "$KEYHUE_APP_SRC" "$INSTALL_DIR/KeyHue.app"
    expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" '앱 폴더가 아닙니다'
    codesign --verify --deep --strict "$KEYHUE_APP_SRC"
}

# 설치 폴더에 앱 말고 남은 것이 없어야 한다(.keyhue-install.* 임시 폴더 포함).
install_dir_entries() {
    (cd "$INSTALL_DIR" && ls -A | tr '\n' ' ')
}

test_paths_with_spaces_install_and_leave_no_staging_folder() {
    export KEYHUE_APP_SRC="$TEST_TMP/Build Output/KeyHue.app" KEYHUE_SKIP_QUIT=1 KEYHUE_SKIP_LAUNCH=1
    make_packaged_app "$KEYHUE_APP_SRC"
    export INSTALL_DIR="$TEST_TMP/My Apps"
    mkdir -p "$INSTALL_DIR"
    expect_success "$REPO_ROOT/scripts/install.sh" --no-build
    codesign --verify --deep --strict "$INSTALL_DIR/KeyHue.app"
    assert_contains "$OUT" 'KeyHue 9.9.9 (42) 설치 완료'
    assert_eq "$(install_dir_entries)" "KeyHue.app "
}

test_existing_file_or_dangling_link_at_destination_is_not_replaced() {
    make_fake_app
    echo "not an app" > "$INSTALL_DIR/KeyHue.app"
    expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" '앱 폴더가 아닙니다'
    assert_eq "$(cat "$INSTALL_DIR/KeyHue.app")" "not an app"
    assert_eq "$(install_dir_entries)" "KeyHue.app "
    rm "$INSTALL_DIR/KeyHue.app"
    ln -s "$TEST_TMP/nowhere/KeyHue.app" "$INSTALL_DIR/KeyHue.app"
    expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" '앱 폴더가 아닙니다'
    [[ -L "$INSTALL_DIR/KeyHue.app" ]] || fail "링크를 바꿨습니다"
}

test_copy_failing_midway_keeps_previous_app_and_cleans_staging() {
    make_fake_app
    make_packaged_app "$INSTALL_DIR/KeyHue.app" 8.8.8
    mkdir -p "$TEST_TMP/bin"
    # 일부만 복사하다 실패하는 ditto(디스크 부족 등)
    cat > "$TEST_TMP/bin/ditto" <<'TOOL'
#!/usr/bin/env bash
mkdir -p "$2/Contents" && echo partial > "$2/Contents/partial"
exit 1
TOOL
    chmod +x "$TEST_TMP/bin/ditto"
    PATH="$TEST_TMP/bin:$PATH" expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_eq "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_DIR/KeyHue.app/Contents/Info.plist")" 8.8.8
    codesign --verify --deep --strict "$INSTALL_DIR/KeyHue.app"
    assert_eq "$(install_dir_entries)" "KeyHue.app "
}

test_failed_final_verification_of_first_install_leaves_nothing_behind() {
    make_fake_app
    mkdir -p "$TEST_TMP/bin"
    cat > "$TEST_TMP/bin/codesign" <<'TOOL'
#!/usr/bin/env bash
if [[ "$*" == "--verify --deep --strict $INSTALL_DIR/KeyHue.app" ]]; then exit 1; fi
exec /usr/bin/codesign "$@"
TOOL
    chmod +x "$TEST_TMP/bin/codesign"
    PATH="$TEST_TMP/bin:$PATH" expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    [[ ! -e "$INSTALL_DIR/KeyHue.app" ]] || fail "검증에 실패한 앱이 남았습니다"
    assert_eq "$(install_dir_entries)" ""
}

test_termination_during_replacement_restores_previous_app() {
    make_fake_app
    make_packaged_app "$INSTALL_DIR/KeyHue.app" 8.8.8
    mkdir -p "$TEST_TMP/bin"
    # 새 앱을 옮긴 직후(최종 검사 중) 설치 스크립트가 TERM을 받는다
    cat > "$TEST_TMP/bin/codesign" <<'TOOL'
#!/usr/bin/env bash
if [[ "$*" == "--verify --deep --strict $INSTALL_DIR/KeyHue.app" ]]; then kill -TERM "$PPID"; exit 0; fi
exec /usr/bin/codesign "$@"
TOOL
    chmod +x "$TEST_TMP/bin/codesign"
    local status=0
    PATH="$TEST_TMP/bin:$PATH" "$REPO_ROOT/scripts/install.sh" --no-build > "$TEST_TMP/out.log" 2>&1 || status=$?
    assert_eq "$status" 143 "TERM으로 끝나야 한다"
    assert_eq "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_DIR/KeyHue.app/Contents/Info.plist")" 8.8.8
    /usr/bin/codesign --verify --deep --strict "$INSTALL_DIR/KeyHue.app"
    assert_eq "$(install_dir_entries)" "KeyHue.app "
}

test_certificate_signed_app_does_not_warn_about_adhoc() {
    make_fake_app
    mkdir -p "$TEST_TMP/bin"
    cat > "$TEST_TMP/bin/codesign" <<'TOOL'
#!/usr/bin/env bash
if [[ "$1" == "-d" ]]; then
    echo 'designated => identifier "io.github.sejoung.keyhue" and certificate leaf = H"0123abcd"' >&2
    exit 0
fi
exec /usr/bin/codesign "$@"
TOOL
    chmod +x "$TEST_TMP/bin/codesign"
    PATH="$TEST_TMP/bin:$PATH" expect_success "$REPO_ROOT/scripts/install.sh" --no-build
    assert_not_contains "$OUT" 'ad-hoc'
    assert_contains "$OUT" 'certificate leaf = H"0123abcd"'
}

# --no-build 없이: 실제 빌드 대신 가짜 build-app.sh를 둔 임시 저장소에서 실행한다.
make_install_repo() {
    mkdir -p "$TEST_TMP/repo/scripts" "$TEST_TMP/Apps"
    cp "$REPO_ROOT/scripts/"{install,app-config}.sh "$TEST_TMP/repo/scripts/"
    echo 7.7.7 > "$TEST_TMP/repo/VERSION"
    cat > "$TEST_TMP/repo/scripts/build-app.sh" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
echo build >> "$TEST_TMP/build-calls"
[[ -z "${FAKE_BUILD_FAILS:-}" ]] || { echo "error: 빌드 실패" >&2; exit 1; }
source scripts/app-config.sh
source "$REPO_ROOT/Tests/scripts/lib.sh"
make_packaged_app "$APP" "$VERSION"
TOOL
    chmod +x "$TEST_TMP/repo/scripts/"*.sh
    unset KEYHUE_APP_SRC VERSION
    export INSTALL_DIR="$TEST_TMP/Apps" KEYHUE_SKIP_QUIT=1 KEYHUE_SKIP_LAUNCH=1
}

test_default_run_builds_first_and_build_failure_installs_nothing() {
    make_install_repo
    FAKE_BUILD_FAILS=1 expect_failure "$TEST_TMP/repo/scripts/install.sh"
    assert_contains "$OUT" '빌드 실패'
    [[ ! -e "$INSTALL_DIR/KeyHue.app" ]] || fail "빌드 실패 후 설치함"
    expect_success "$TEST_TMP/repo/scripts/install.sh"
    assert_eq "$(wc -l < "$TEST_TMP/build-calls" | tr -d ' ')" 2
    assert_contains "$OUT" 'KeyHue 7.7.7 (42) 설치 완료'
    codesign --verify --deep --strict "$INSTALL_DIR/KeyHue.app"
}
