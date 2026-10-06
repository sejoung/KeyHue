# scripts/uninstall.sh — HOME과 시스템 명령(defaults·tccutil·sfltool·osascript·pkill·pgrep)을
# 가짜로 바꿔, 실제 설정·권한·입력 소스·프로세스를 건드리지 않는다(ADR 0074).
make_fake_system() {
    export HOME="$TEST_TMP/home" KEYHUE_APP_DIRS="$TEST_TMP/Apps" KEYHUE_BACKUP_DIR="$TEST_TMP/backup"
    export CALLS="$TEST_TMP/calls.log" STATE="$TEST_TMP/state" LSREGISTER="$TEST_TMP/bin/lsregister"
    mkdir -p "$HOME/Library/Input Methods" "$HOME/Library/Logs/KeyHue" "$HOME/Library/Application Support/KeyHue" \
        "$HOME/Library/Preferences" "$KEYHUE_APP_DIRS" "$STATE" "$TEST_TMP/bin"
    make_packaged_app "$KEYHUE_APP_DIRS/KeyHue.app"
    cp -R "$KEYHUE_APP_DIRS/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app" "$HOME/Library/Input Methods/"
    echo log > "$HOME/Library/Logs/KeyHue/KeyHue.log"
    # The app's own steps (UninstallPreparation): names and statuses only.
    echo enabled > "$STATE/login"
    cat > "$KEYHUE_APP_DIRS/KeyHue.app/Contents/MacOS/KeyHue" <<'SH'
#!/bin/bash
case "$1" in
    --keyhue-login-item-status) echo "login item: $(cat "$STATE/login")" ;;
    --keyhue-prepare-uninstall)
        : > "$STATE/inputsources"; echo notRegistered > "$STATE/login"
        echo "ok leave KeyHue input mode not selected"; echo "ok remove login item" ;;
esac
SH
    printf 'io.github.sejoung.keyhue\nio.github.sejoung.keyhue.inputmethod.spike\ncom.other.app\n' > "$STATE/domains"
    printf '"Bundle ID" = "io.github.sejoung.keyhue.inputmethod.spike";\n"Input Mode" = "io.github.sejoung.keyhue.inputmethod.spike.Hangul";\n' > "$STATE/inputsources"
    printf 'Disposition: [disabled, allowed, notified] (0xa)\nURL: file:///Applications/KeyHue.app/\nBundle Identifier: io.github.sejoung.keyhue\n' > "$STATE/btm"
    : > "$CALLS"
    cat > "$TEST_TMP/bin/defaults" <<'SH'
#!/bin/bash
echo "defaults $*" >> "$CALLS"
case "$1" in
    domains) paste -sd, - < "$STATE/domains" | sed 's/,/, /g' ;;
    read)
        if [[ "$2" == com.apple.inputsources ]]; then cat "$STATE/inputsources"; exit 0; fi
        if [[ "$2" == -g ]]; then [[ -f "$STATE/indicator" ]] && cat "$STATE/indicator" && exit 0; exit 1; fi
        grep -qx "$2" "$STATE/domains" || exit 1 ;;
    export)
        if [[ "$3" == - ]]; then
            printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>AppleEnabledThirdPartyInputSources</key><array><dict><key>Bundle ID</key><string>io.github.sejoung.keyhue.inputmethod.spike</string></dict><dict><key>Bundle ID</key><string>com.other.im</string></dict></array></dict></plist>'
        else
            echo plist > "$3"
        fi ;;
    import) cp "$3" "$STATE/imported.plist"; : > "$STATE/inputsources" ;;
    delete)
        if [[ "$2" == -g ]]; then rm -f "$STATE/indicator"; exit 0; fi
        grep -vx "$2" "$STATE/domains" > "$STATE/domains.new"; mv "$STATE/domains.new" "$STATE/domains" ;;
esac
exit 0
SH
    printf '#!/bin/bash\necho "sfltool $*" >> "$CALLS"\ncat "$STATE/btm"\n' > "$TEST_TMP/bin/sfltool"
    for tool in tccutil osascript pkill pgrep lsregister; do
        printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n%s\n' "$tool" "$( [[ $tool == pgrep ]] && echo 'exit 1' || echo 'exit 0')" > "$TEST_TMP/bin/$tool"
    done
    chmod +x "$TEST_TMP/bin/"*
    export PATH="$TEST_TMP/bin:$PATH"
}

test_dry_run_lists_everything_and_removes_nothing() {
    make_fake_system
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --dry-run
    assert_contains "$OUT" "file: $KEYHUE_APP_DIRS/KeyHue.app"
    assert_contains "$OUT" "file: $HOME/Library/Input Methods/KeyHueInputMethodSpike.app"
    assert_contains "$OUT" "file: $HOME/Library/Logs/KeyHue"
    assert_contains "$OUT" "settings: io.github.sejoung.keyhue.inputmethod.spike"
    assert_contains "$OUT" "input source: io.github.sejoung.keyhue.inputmethod.spike.Hangul"
    assert_not_contains "$OUT" "com.other.app"
    [[ -d "$KEYHUE_APP_DIRS/KeyHue.app" && -d "$HOME/Library/Logs/KeyHue" ]] || fail "dry-run이 지움"
    assert_not_contains "$(cat "$CALLS")" "tccutil"
    assert_not_contains "$(cat "$CALLS")" "defaults delete"
}

test_yes_removes_files_settings_and_permissions_and_keeps_a_backup() {
    make_fake_system
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --yes
    for path in "$KEYHUE_APP_DIRS/KeyHue.app" "$HOME/Library/Input Methods/KeyHueInputMethodSpike.app" \
                "$HOME/Library/Logs/KeyHue" "$HOME/Library/Application Support/KeyHue"; do
        [[ ! -e "$path" ]] || fail "남음: $path"
    done
    local calls; calls="$(cat "$CALLS")"
    assert_contains "$calls" "defaults delete io.github.sejoung.keyhue"
    assert_contains "$calls" "defaults delete io.github.sejoung.keyhue.inputmethod.spike"
    assert_not_contains "$calls" "defaults delete com.other.app"
    for id in io.github.sejoung.keyhue io.github.sejoung.keyhue.inputmethod.spike; do
        assert_contains "$calls" "tccutil reset All $id"
    done
    [[ -f "$KEYHUE_BACKUP_DIR/io.github.sejoung.keyhue.plist" && -f "$KEYHUE_BACKUP_DIR/Logs/KeyHue.log" ]] || fail "백업 없음"
    assert_contains "$OUT" "남은 것 없음"
}

test_no_backup_leaves_no_folder() {
    make_fake_system
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --yes --no-backup
    [[ ! -e "$KEYHUE_BACKUP_DIR" ]] || fail "백업을 만듦"
}

test_another_app_named_keyhue_is_left_alone() {
    make_fake_system
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.other.keyhue' "$KEYHUE_APP_DIRS/KeyHue.app/Contents/Info.plist"
    : > "$STATE/inputsources" # without its own app, enabled modes can't be turned off (next test)
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --yes --no-backup
    [[ -d "$KEYHUE_APP_DIRS/KeyHue.app" ]] || fail "다른 앱을 지움"
    assert_contains "$OUT" "다른 앱이라 건드리지 않습니다"
}

test_check_reports_leftovers_then_a_clean_state() {
    make_fake_system
    expect_failure "$REPO_ROOT/scripts/uninstall.sh" --check
    assert_contains "$OUT" "남아 있는 것"
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --yes --no-backup
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --check
    assert_contains "$OUT" "남긴 것이 없습니다"
}

test_without_a_terminal_it_asks_for_yes() {
    make_fake_system
    # setsid가 없는 macOS에서도: 확인할 터미널이 없으면 지우지 않는다.
    if ( : < /dev/tty ) 2>/dev/null; then return 0; fi
    expect_failure "$REPO_ROOT/scripts/uninstall.sh"
    assert_contains "$OUT" "--yes"
    [[ -d "$KEYHUE_APP_DIRS/KeyHue.app" ]] || fail "확인 없이 지움"
}

test_unknown_arguments_are_rejected() {
    make_fake_system
    expect_failure "$REPO_ROOT/scripts/uninstall.sh" --everything
    assert_contains "$OUT" "usage"
    [[ -d "$KEYHUE_APP_DIRS/KeyHue.app" ]] || fail "잘못된 인자로 지움"
}

test_without_its_app_enabled_input_sources_fail_with_instructions() {
    make_fake_system
    rm -rf "$KEYHUE_APP_DIRS/KeyHue.app"
    expect_failure "$REPO_ROOT/scripts/uninstall.sh" --yes --no-backup
    assert_contains "$OUT" "입력 소스에서 직접 빼세요"
}

test_an_older_app_without_the_step_fails_with_instructions() {
    make_fake_system
    printf '#!/bin/bash\nexit 0\n' > "$KEYHUE_APP_DIRS/KeyHue.app/Contents/MacOS/KeyHue"
    expect_failure "$REPO_ROOT/scripts/uninstall.sh" --yes --no-backup
    assert_contains "$OUT" "scripts/install.sh로 새 빌드를 설치한 뒤"
}

test_an_app_that_keeps_running_is_stopped_after_the_timeout() {
    make_fake_system
    printf '#!/bin/bash\nsleep 30\n' > "$KEYHUE_APP_DIRS/KeyHue.app/Contents/MacOS/KeyHue"
    KEYHUE_PREPARE_TIMEOUT=1 expect_failure "$REPO_ROOT/scripts/uninstall.sh" --yes --no-backup
    assert_contains "$OUT" "끝내지 않았습니다"
}

test_empty_preference_files_are_removed_too() {
    make_fake_system
    echo '{}' > "$HOME/Library/Preferences/ai.realdraw.KeyHue.plist"
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --yes --no-backup
    [[ ! -e "$HOME/Library/Preferences/ai.realdraw.KeyHue.plist" ]] || fail "빈 설정 파일이 남음"
}

test_modes_left_after_turning_off_are_removed_from_the_list_only() {
    make_fake_system
    printf '#!/bin/bash\necho "ok leave KeyHue input mode not selected"\n' > "$KEYHUE_APP_DIRS/KeyHue.app/Contents/MacOS/KeyHue"
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --yes
    assert_contains "$OUT" "남은 입력 소스 항목 정리"
    local imported; imported="$(plutil -p "$STATE/imported.plist")"
    assert_contains "$imported" "com.other.im"
    assert_not_contains "$imported" "io.github.sejoung.keyhue.inputmethod.spike"
    [[ -f "$KEYHUE_BACKUP_DIR/com.apple.inputsources.plist" ]] || fail "입력 소스 목록 백업 없음"
}

test_permissions_are_reset_while_the_bundles_still_exist() {
    make_fake_system
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --yes --no-backup
    local calls; calls="$(cat "$CALLS")"
    assert_contains "$calls" "lsregister -f $KEYHUE_APP_DIRS/KeyHue.app"
    assert_contains "$calls" "lsregister -f $HOME/Library/Input Methods/KeyHueInputMethodSpike.app"
}

test_an_enabled_login_item_is_a_leftover_and_a_disabled_record_is_not() {
    make_fake_system
    : > "$STATE/inputsources"
    # With the app: its own answer.
    expect_failure "$REPO_ROOT/scripts/uninstall.sh" --check
    assert_contains "$OUT" "login item"
    echo notRegistered > "$STATE/login"
    expect_failure "$REPO_ROOT/scripts/uninstall.sh" --check
    assert_not_contains "$OUT" "login item"
    # Without the app: Background Task Management, where a removed item stays [disabled].
    rm -rf "$KEYHUE_APP_DIRS/KeyHue.app"
    sed -i '' 's/disabled/enabled/' "$STATE/btm"
    expect_failure "$REPO_ROOT/scripts/uninstall.sh" --check
    assert_contains "$OUT" "login item"
    sed -i '' 's/enabled/disabled/' "$STATE/btm"
    expect_failure "$REPO_ROOT/scripts/uninstall.sh" --check
    assert_not_contains "$OUT" "login item"
}

test_the_hidden_macos_indicator_goes_back_to_the_default() {
    make_fake_system
    echo 0 > "$STATE/indicator"
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --dry-run
    assert_contains "$OUT" "TSMLanguageIndicatorEnabled=0"
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --yes
    [[ ! -f "$STATE/indicator" ]] || fail "숨김이 남음"
    assert_contains "$(cat "$KEYHUE_BACKUP_DIR/global-settings.txt")" "TSMLanguageIndicatorEnabled=0"
}

# sfltool dumpbtm asks for an administrator password on every call.
test_sfltool_is_asked_at_most_once_per_run() {
    make_fake_system
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --dry-run
    assert_contains "$OUT" "login item: io.github.sejoung.keyhue"
    assert_not_contains "$(cat "$CALLS")" "sfltool"
    : > "$CALLS"
    expect_success "$REPO_ROOT/scripts/uninstall.sh" --yes --no-backup
    assert_eq "$(grep -c '^sfltool' "$CALLS")" "1" "sfltool 호출 수"
}
