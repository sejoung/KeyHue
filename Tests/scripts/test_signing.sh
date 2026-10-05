# scripts/signing.sh (ADR 0021). 실제 키체인은 건드리지 않는다(generate, github, status만).

setup_keys() {
    export KEYHUE_SIGNING_DIR="$TEST_TMP/keys"
    "$REPO_ROOT/scripts/signing.sh" generate >/dev/null
}

test_generate_writes_private_files() {
    setup_keys
    [[ -f "$KEYHUE_SIGNING_DIR/signing.p12" ]] || fail "p12 없음"
    assert_eq "$(stat -f %Lp "$KEYHUE_SIGNING_DIR")" "700"
    assert_eq "$(stat -f %Lp "$KEYHUE_SIGNING_DIR/signing.p12")" "600"
    assert_eq "$(stat -f %Lp "$KEYHUE_SIGNING_DIR/signing.password")" "600"
    local subject
    subject="$(/usr/bin/openssl pkcs12 -in "$KEYHUE_SIGNING_DIR/signing.p12" -nokeys -passin "file:$KEYHUE_SIGNING_DIR/signing.password" 2>/dev/null | /usr/bin/openssl x509 -noout -subject)"
    assert_contains "$subject" "KeyHue Development"
}

test_generate_refuses_to_overwrite() {
    setup_keys
    expect_failure "$REPO_ROOT/scripts/signing.sh" generate
    assert_contains "$OUT" "이미 키 파일"
}

test_p12_survives_base64_like_github_secrets() {
    setup_keys
    base64 -i "$KEYHUE_SIGNING_DIR/signing.p12" | tr -d '\n' > secret.txt
    base64 --decode -i secret.txt > decoded.p12
    cmp -s decoded.p12 "$KEYHUE_SIGNING_DIR/signing.p12" || fail "base64 왕복 후 달라짐"
}

test_status_shows_fingerprint() {
    setup_keys
    expect_success "$REPO_ROOT/scripts/signing.sh" status
    assert_contains "$OUT" "지문(SHA-1):"
}

# 두 번째 값을 복사하자마자 클립보드를 비우던 버그의 회귀 테스트
test_github_copies_both_values_before_clearing() {
    setup_keys
    mkdir -p bin
    cat > bin/pbcopy <<'STUB'
#!/usr/bin/env bash
value="$(cat)"
echo "${#value}:${value:0:8}" >> "$TEST_TMP/clipboard.log"
STUB
    chmod +x bin/pbcopy
    printf '\n\n' | PATH="$PWD/bin:$PATH" "$REPO_ROOT/scripts/signing.sh" github >/dev/null
    local p12_len password
    p12_len="$(base64 -i "$KEYHUE_SIGNING_DIR/signing.p12" | tr -d '\n' | wc -c | tr -d ' ')"
    password="$(tr -d '\n' < "$KEYHUE_SIGNING_DIR/signing.password")"
    assert_eq "$(sed -n 1p "$TEST_TMP/clipboard.log" | cut -d: -f1)" "$p12_len" "1번째는 p12"
    assert_eq "$(sed -n 2p "$TEST_TMP/clipboard.log")" "${#password}:${password:0:8}" "2번째는 암호"
    assert_eq "$(sed -n 3p "$TEST_TMP/clipboard.log")" "0:" "마지막에만 비운다"
    assert_eq "$(wc -l < "$TEST_TMP/clipboard.log" | tr -d ' ')" "3"
}

test_install_without_files_explains_what_to_do() {
    export KEYHUE_SIGNING_DIR="$TEST_TMP/none"
    expect_failure "$REPO_ROOT/scripts/signing.sh" install
    assert_contains "$OUT" "scripts/signing.sh create"
}

# 키체인을 건드리지 않도록 security를 가짜로 바꾼다. 호출 인자는 security.log에 남는다.
# FAKE_IDENTITY가 있으면 find-identity가 "KeyHue Development"를 보고한다.
stub_security() {
    mkdir -p "$TEST_TMP/bin"
    cat > "$TEST_TMP/bin/security" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$TEST_TMP/security.log"
if [[ "$1" == find-identity && -n "${FAKE_IDENTITY:-}" ]]; then
    echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "KeyHue Development"'
fi
exit 0
STUB
    chmod +x "$TEST_TMP/bin/security"
    export PATH="$TEST_TMP/bin:$PATH"
    : > "$TEST_TMP/security.log"
}

test_status_with_only_one_of_the_two_files() {
    stub_security
    setup_keys
    mv "$KEYHUE_SIGNING_DIR/signing.password" "$TEST_TMP/password.bak"
    expect_success "$REPO_ROOT/scripts/signing.sh" status
    assert_contains "$OUT" "$KEYHUE_SIGNING_DIR/signing.p12"
    assert_not_contains "$OUT" "지문"
    mv "$TEST_TMP/password.bak" "$KEYHUE_SIGNING_DIR/signing.password"
    rm "$KEYHUE_SIGNING_DIR/signing.p12"
    expect_success "$REPO_ROOT/scripts/signing.sh" status
    assert_contains "$OUT" "키 파일:   없음"
    assert_not_contains "$OUT" "지문"
}

test_install_and_github_require_both_files_before_touching_anything() {
    stub_security
    setup_keys
    mkdir -p "$TEST_TMP/bin"
    printf '#!/bin/sh\necho pbcopy >> "$TEST_TMP/pbcopy.log"\n' > "$TEST_TMP/bin/pbcopy"
    chmod +x "$TEST_TMP/bin/pbcopy"
    rm "$KEYHUE_SIGNING_DIR/signing.password"
    expect_failure "$REPO_ROOT/scripts/signing.sh" install
    assert_contains "$OUT" "signing.password이 없습니다"
    expect_failure "$REPO_ROOT/scripts/signing.sh" github < /dev/null
    assert_contains "$OUT" "키 파일이 없습니다"
    assert_not_contains "$(cat "$TEST_TMP/security.log")" "import"
    [[ ! -e "$TEST_TMP/pbcopy.log" ]] || fail "키 파일 없이 클립보드에 복사했습니다"
}

test_create_with_existing_key_files_does_not_touch_keychain() {
    stub_security
    setup_keys
    cp "$KEYHUE_SIGNING_DIR/signing.p12" "$TEST_TMP/before.p12"
    expect_failure "$REPO_ROOT/scripts/signing.sh" create
    assert_contains "$OUT" "이미 키 파일이 있습니다"
    assert_contains "$OUT" "scripts/signing.sh install"
    cmp -s "$TEST_TMP/before.p12" "$KEYHUE_SIGNING_DIR/signing.p12" || fail "기존 키를 바꿨습니다"
    assert_eq "$(cat "$TEST_TMP/security.log")" "" "키체인을 조회·변경하면 안 된다"
    FAKE_IDENTITY=1 expect_failure "$REPO_ROOT/scripts/signing.sh" create --replace
    assert_contains "$OUT" "이미 키 파일이 있습니다"
    assert_not_contains "$(cat "$TEST_TMP/security.log")" "delete-identity"
}

test_create_without_replace_keeps_existing_keychain_identity() {
    stub_security
    export KEYHUE_SIGNING_DIR="$TEST_TMP/keys" FAKE_IDENTITY=1
    expect_failure "$REPO_ROOT/scripts/signing.sh" create
    assert_contains "$OUT" "scripts/signing.sh create --replace"
    assert_not_contains "$(cat "$TEST_TMP/security.log")" "delete-identity"
    [[ ! -e "$KEYHUE_SIGNING_DIR/signing.p12" ]] || fail "키 파일을 만들었습니다"
}

test_create_replace_gives_up_after_bounded_delete_attempts() {
    stub_security
    # 지워도 계속 남아 있는 인증서
    export KEYHUE_SIGNING_DIR="$TEST_TMP/keys" FAKE_IDENTITY=1
    expect_failure "$REPO_ROOT/scripts/signing.sh" create --replace
    assert_contains "$OUT" "기존 인증서를 지우지 못했습니다"
    assert_eq "$(grep -c '^delete-identity -c KeyHue Development' "$TEST_TMP/security.log")" 5
    assert_not_contains "$(cat "$TEST_TMP/security.log")" "import"
    [[ ! -e "$KEYHUE_SIGNING_DIR/signing.p12" ]] || fail "지우지 못했는데 새 키를 만들었습니다"
}

# 이전 실행이 남긴 암호 파일(예: 다른 Mac에서 복사하며 644가 됨)도 새 암호를 쓰면 600이어야 한다(ADR 0021: 700/600).
test_generate_makes_a_stale_password_file_private() {
    export KEYHUE_SIGNING_DIR="$TEST_TMP/keys"
    mkdir -p "$KEYHUE_SIGNING_DIR"
    echo stale > "$KEYHUE_SIGNING_DIR/signing.password"
    chmod 644 "$KEYHUE_SIGNING_DIR/signing.password"
    expect_success "$REPO_ROOT/scripts/signing.sh" generate
    assert_eq "$(stat -f %Lp "$KEYHUE_SIGNING_DIR/signing.p12")" "600"
    assert_eq "$(stat -f %Lp "$KEYHUE_SIGNING_DIR/signing.password")" "600" "암호 파일 권한"
}

test_unknown_or_missing_command_prints_usage() {
    local status
    for command in "" bogus; do
        status=0
        OUT="$("$REPO_ROOT/scripts/signing.sh" $command 2>&1)" || status=$?
        assert_eq "$status" 64 "'$command' 종료 코드"
        assert_contains "$OUT" "scripts/signing.sh create [--replace]"
    done
}

test_github_uses_gh_with_the_repository_from_origin() {
    stub_security
    setup_keys
    cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$* <$(cat)>" >> "$TEST_TMP/gh.log"
STUB
    printf '#!/bin/sh\necho pbcopy >> "$TEST_TMP/pbcopy.log"\n' > "$TEST_TMP/bin/pbcopy"
    chmod +x "$TEST_TMP/bin/gh" "$TEST_TMP/bin/pbcopy"
    git_quiet init "$TEST_TMP/repo"
    cd "$TEST_TMP/repo" || exit 1
    local p12 password url
    p12="$(base64 -i "$KEYHUE_SIGNING_DIR/signing.p12")"
    password="$(cat "$KEYHUE_SIGNING_DIR/signing.password")"
    for url in git@github.com:someone/KeyHue.git https://github.com/someone/KeyHue.git https://github.com/someone/KeyHue; do
        rm -f "$TEST_TMP/gh.log"
        git_quiet remote remove origin || true
        git_quiet remote add origin "$url"
        expect_success "$REPO_ROOT/scripts/signing.sh" github < /dev/null
        assert_eq "$(sed -n 1p "$TEST_TMP/gh.log")" "secret set KEYHUE_SIGNING_P12 --repo someone/KeyHue <$p12>" "$url"
        assert_eq "$(sed -n 2p "$TEST_TMP/gh.log")" "secret set KEYHUE_SIGNING_PASSWORD --repo someone/KeyHue <$password>" "$url"
    done
    [[ ! -e "$TEST_TMP/pbcopy.log" ]] || fail "gh가 있는데 클립보드를 썼습니다"
}
