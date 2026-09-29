# scripts/lint.sh 자체 테스트

test_flags_variable_followed_by_hangul() {
    # 검사 대상 패턴을 이 파일에 그대로 쓰면 lint가 이 파일을 잡으므로 printf로 만든다.
    printf '#!/usr/bin/env bash\nREMOTE=origin\necho "$%s로 push"\n' REMOTE > bad.sh
    SHELLCHECK=/nonexistent expect_failure "$REPO_ROOT/scripts/lint.sh" "$PWD/bad.sh"
    assert_contains "$OUT" "bad.sh:3:"
}

test_accepts_braced_variable_and_comments() {
    cat > good.sh <<'SH'
#!/usr/bin/env bash
REMOTE=origin
# 주석 속 $REMOTE로 는 검사하지 않는다
echo "${REMOTE}로 push"
SH
    SHELLCHECK=/nonexistent expect_success "$REPO_ROOT/scripts/lint.sh" "$PWD/good.sh"
}
