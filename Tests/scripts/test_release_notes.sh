# scripts/release-notes.sh (ADR 0017, 0021)

make_notes_repo() {
    git_quiet init "$TEST_TMP/repo"
    cd "$TEST_TMP/repo" || exit 1
    mkdir -p scripts
    cp "$REPO_ROOT/scripts/release-notes.sh" scripts/
    echo a > a && git_quiet add -A && git_quiet commit -m "첫 기능"
    git_quiet tag -a v0.1.0 -m "KeyHue 0.1.0" -m "- 첫 기능"
    echo b >> a && git_quiet commit -am "버그 수정"
    echo c >> a && git_quiet commit -am "두 번째 기능"
}

test_uses_annotated_tag_message() {
    make_notes_repo
    git_quiet tag -a v0.2.0 -m "KeyHue 0.2.0" -m "- 태그에 적은 변경 내역"
    expect_success scripts/release-notes.sh v0.2.0
    assert_contains "$OUT" "- 태그에 적은 변경 내역"
    assert_contains "$OUT" "KeyHue-0.2.0.zip"
}

test_lightweight_tag_falls_back_to_commits_since_previous_tag() {
    make_notes_repo
    git_quiet tag v0.2.0
    expect_success scripts/release-notes.sh v0.2.0
    assert_contains "$OUT" "- 두 번째 기능"
    assert_contains "$OUT" "- 버그 수정"
    assert_not_contains "$OUT" "- 첫 기능" "이전 태그의 커밋은 빠져야 한다"
}

test_permission_text_depends_on_signing() {
    make_notes_repo
    git_quiet tag v0.2.0
    expect_success scripts/release-notes.sh v0.2.0
    assert_contains "$OUT" "allow Input Monitoring / Accessibility again after each update"
    KEYHUE_SIGNED=1 expect_success scripts/release-notes.sh v0.2.0
    assert_contains "$OUT" "permissions now stay after updates"
}

test_includes_sha_when_package_exists() {
    make_notes_repo
    git_quiet tag v0.2.0
    mkdir -p build/dist
    echo "abc123  KeyHue-0.2.0.zip" > build/dist/KeyHue-0.2.0.zip.sha256
    expect_success scripts/release-notes.sh v0.2.0
    assert_contains "$OUT" '`abc123`'
}

test_unknown_tag_fails() {
    make_notes_repo
    expect_failure scripts/release-notes.sh v9.9.9
    assert_contains "$OUT" "태그 v9.9.9가 없습니다"
}

test_requires_a_tag_argument() {
    make_notes_repo
    expect_failure scripts/release-notes.sh
    assert_contains "$OUT" "usage: release-notes.sh <tag>"
}

test_annotated_tag_without_body_falls_back_to_commits() {
    make_notes_repo
    git_quiet tag -a v0.2.0 -m "KeyHue 0.2.0"
    expect_success scripts/release-notes.sh v0.2.0
    assert_contains "$OUT" "- 두 번째 기능"
    assert_contains "$OUT" "- 버그 수정"
    assert_not_contains "$OUT" "- 첫 기능"
}

test_lightweight_tag_on_the_first_commit_lists_it() {
    git_quiet init "$TEST_TMP/repo"
    cd "$TEST_TMP/repo" || exit 1
    mkdir -p scripts
    cp "$REPO_ROOT/scripts/release-notes.sh" scripts/
    echo a > a && git_quiet add -A && git_quiet commit -m "첫 커밋"
    git_quiet tag v0.0.1
    expect_success scripts/release-notes.sh v0.0.1
    assert_contains "$OUT" "- 첫 커밋"
}

test_fallback_skips_merge_commits() {
    make_notes_repo
    git_quiet checkout -b feature
    echo f > f && git_quiet add f && git_quiet commit -m "브랜치 기능"
    git_quiet checkout main
    git_quiet merge --no-ff -m "Merge branch 'feature'" feature
    git_quiet tag v0.2.0
    expect_success scripts/release-notes.sh v0.2.0
    assert_contains "$OUT" "- 브랜치 기능"
    assert_not_contains "$OUT" "Merge branch"
}

test_strips_pgp_signature_from_tag_message() {
    make_notes_repo
    printf 'KeyHue 0.2.0\n\n- 서명된 변경\n-----BEGIN PGP SIGNATURE-----\nAAAA\n-----END PGP SIGNATURE-----\n' > "$TEST_TMP/message"
    git_quiet tag -a v0.2.0 -F "$TEST_TMP/message"
    expect_success scripts/release-notes.sh v0.2.0
    assert_contains "$OUT" "- 서명된 변경"
    assert_not_contains "$OUT" "PGP"
    assert_not_contains "$OUT" "AAAA"
}

test_tag_message_is_printed_literally_not_evaluated() {
    make_notes_repo
    # shellcheck disable=SC2016 # 셸 문법을 글자 그대로 태그 메시지에 넣는다
    local line='- 한글 "따옴표" $HOME `id` $(touch pwned) \n'
    git_quiet tag -a v0.2.0 -m "KeyHue 0.2.0" -m "$line"
    expect_success scripts/release-notes.sh v0.2.0
    assert_contains "$OUT" "$line"
    [[ ! -e pwned && ! -e scripts/pwned ]] || fail "태그 메시지를 셸로 실행했습니다"
}
