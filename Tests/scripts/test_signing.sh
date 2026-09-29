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
