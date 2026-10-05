# scripts/ci-import-signing.sh (ADR 0021). security는 가짜다: 실제 키체인·검색 목록을 바꾸지 않는다.

stub_ci_security() {
    mkdir -p "$TEST_TMP/bin"
    cat > "$TEST_TMP/bin/security" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_TMP/security.log"
case "$1" in
    list-keychains)
        if [[ "$*" == "list-keychains -d user" ]]; then
            printf '    "%s"\n' "/Users/me/Library/Keychains/login.keychain-db" "/Users/me/Library/Keychains/My Team.keychain-db"
        else
            for arg in "$@"; do echo "$arg"; done > "$TEST_TMP/search-list"
        fi
        ;;
    find-identity)
        [[ -n "${FAKE_NO_IDENTITY:-}" ]] || echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "KeyHue Development"'
        ;;
    import)
        cp "$2" "$TEST_TMP/imported.p12"
        ;;
esac
exit 0
STUB
    chmod +x "$TEST_TMP/bin/security"
    export PATH="$TEST_TMP/bin:$PATH" RUNNER_TEMP="$TEST_TMP/runner temp"
    mkdir -p "$RUNNER_TEMP"
    : > "$TEST_TMP/security.log"
}

test_missing_secrets_fail_before_creating_a_keychain() {
    stub_ci_security
    unset KEYHUE_SIGNING_P12 KEYHUE_SIGNING_PASSWORD
    expect_failure "$REPO_ROOT/scripts/ci-import-signing.sh"
    assert_contains "$OUT" "KEYHUE_SIGNING_P12 is empty"
    KEYHUE_SIGNING_P12=abc KEYHUE_SIGNING_PASSWORD='' expect_failure "$REPO_ROOT/scripts/ci-import-signing.sh"
    assert_contains "$OUT" "KEYHUE_SIGNING_PASSWORD is empty"
    assert_eq "$(cat "$TEST_TMP/security.log")" "" "secret 없이 security를 호출했습니다"
}

test_imports_into_temporary_keychain_and_keeps_existing_search_list() {
    stub_ci_security
    printf 'fake p12 bytes' > "$TEST_TMP/source.p12"
    export KEYHUE_SIGNING_P12 KEYHUE_SIGNING_PASSWORD='p@ss word' GITHUB_OUTPUT="$TEST_TMP/github-output"
    KEYHUE_SIGNING_P12="$(base64 -i "$TEST_TMP/source.p12")"
    expect_success "$REPO_ROOT/scripts/ci-import-signing.sh"
    local keychain="$RUNNER_TEMP/keyhue-signing.keychain-db"
    cmp -s "$TEST_TMP/source.p12" "$TEST_TMP/imported.p12" || fail "base64 secret을 그대로 풀지 못했습니다"
    assert_contains "$(cat "$TEST_TMP/security.log")" "-P p@ss word -T /usr/bin/codesign"
    # 새 키체인을 맨 앞에 두고, 공백이 있는 기존 키체인 경로도 그대로 유지한다
    assert_eq "$(cat "$TEST_TMP/search-list")" "list-keychains
-d
user
-s
$keychain
/Users/me/Library/Keychains/login.keychain-db
/Users/me/Library/Keychains/My Team.keychain-db"
    assert_contains "$OUT" "SHA-1: 0123456789ABCDEF0123456789ABCDEF01234567"
    assert_eq "$(cat "$GITHUB_OUTPUT")" "identity=0123456789ABCDEF0123456789ABCDEF01234567"
    # 신뢰 설정은 하지 않는다(ADR 0021: 러너에서 -60005로 실패)
    assert_not_contains "$(cat "$TEST_TMP/security.log")" "add-trusted-cert"
}

test_fails_when_imported_certificate_has_no_keyhue_identity() {
    stub_ci_security
    export KEYHUE_SIGNING_P12 KEYHUE_SIGNING_PASSWORD=pw FAKE_NO_IDENTITY=1 GITHUB_OUTPUT="$TEST_TMP/github-output"
    KEYHUE_SIGNING_P12="$(printf x | base64)"
    expect_failure "$REPO_ROOT/scripts/ci-import-signing.sh"
    assert_contains "$OUT" "::error::'KeyHue Development' identity not found"
    [[ ! -s "$GITHUB_OUTPUT" ]] || fail "identity 없이 출력을 남겼습니다"
}

test_cleanup_deletes_only_the_temporary_keychain() {
    stub_ci_security
    expect_success "$REPO_ROOT/scripts/ci-import-signing.sh" --cleanup
    assert_eq "$(cat "$TEST_TMP/security.log")" "delete-keychain $RUNNER_TEMP/keyhue-signing.keychain-db"
}
