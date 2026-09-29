# scripts/install.sh — 실제 /Applications와 실행 중인 KeyHue는 건드리지 않는다.

make_fake_app() {
    local app="$TEST_TMP/Fake/KeyHue.app"
    mkdir -p "$app/Contents/MacOS"
    cp /usr/bin/true "$app/Contents/MacOS/KeyHue"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.sejoung.keyhue.test</string>
<key>CFBundleExecutable</key><string>KeyHue</string>
<key>CFBundleShortVersionString</key><string>9.9.9</string>
<key>CFBundleVersion</key><string>42</string>
</dict></plist>
PLIST
    codesign --force --sign - "$app" >/dev/null 2>&1
    export KEYHUE_APP_SRC="$app" KEYHUE_SKIP_QUIT=1 KEYHUE_SKIP_LAUNCH=1
}

test_installs_into_install_dir_and_warns_about_adhoc() {
    make_fake_app
    mkdir -p "$TEST_TMP/Apps"
    INSTALL_DIR="$TEST_TMP/Apps" expect_success "$REPO_ROOT/scripts/install.sh" --no-build
    [[ -x "$TEST_TMP/Apps/KeyHue.app/Contents/MacOS/KeyHue" ]] || fail "설치되지 않음"
    assert_contains "$OUT" "ad-hoc 서명 빌드입니다"
    assert_contains "$OUT" "KeyHue 9.9.9 (42) 설치 완료"
}

test_replaces_previous_install() {
    make_fake_app
    mkdir -p "$TEST_TMP/Apps/KeyHue.app/Contents"
    echo stale > "$TEST_TMP/Apps/KeyHue.app/Contents/stale.txt"
    INSTALL_DIR="$TEST_TMP/Apps" expect_success "$REPO_ROOT/scripts/install.sh" --no-build
    [[ ! -e "$TEST_TMP/Apps/KeyHue.app/Contents/stale.txt" ]] || fail "이전 설치본이 남아 있음"
}

test_refuses_unwritable_install_dir() {
    make_fake_app
    INSTALL_DIR=/System expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" "쓸 수 없습니다"
}

test_missing_build_explains_what_to_do() {
    export KEYHUE_APP_SRC="$TEST_TMP/nothing/KeyHue.app" KEYHUE_SKIP_QUIT=1 KEYHUE_SKIP_LAUNCH=1
    INSTALL_DIR="$TEST_TMP" expect_failure "$REPO_ROOT/scripts/install.sh" --no-build
    assert_contains "$OUT" "build-app.sh"
}
