# 스크립트 테스트 공용 도우미. run.sh가 테스트마다 source 한다.

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "${3:-값이 다릅니다}: expected '$2', got '$1'"
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "${3:-출력에 없습니다}: '$2' not in: $1"
}

assert_not_contains() {
    [[ "$1" != *"$2"* ]] || fail "${3:-출력에 있으면 안 됩니다}: '$2' in: $1"
}

# 명령이 실패해야 한다. 출력은 $OUT에 담긴다.
expect_failure() {
    if OUT="$("$@" 2>&1)"; then
        fail "실패해야 하는 명령이 성공했습니다: $*"$'\n'"$OUT"
    fi
}

# 명령이 성공해야 한다. 출력은 $OUT에 담긴다.
expect_success() {
    OUT="$("$@" 2>&1)" || fail "명령이 실패했습니다: $*"$'\n'"$OUT"
}

git_quiet() {
    git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1
}

# 원격(bare) + 작업 저장소. VERSION과 scripts/release.sh를 가진 최소 저장소를 만든다.
make_release_repo() {
    local version="${1:-0.1.0}"
    git_quiet init --bare "$TEST_TMP/remote.git"
    git_quiet init "$TEST_TMP/work"
    cd "$TEST_TMP/work" || exit 1
    git_quiet checkout -b main
    mkdir -p scripts
    cp "$REPO_ROOT/scripts/release.sh" scripts/
    echo "$version" > VERSION
    echo "readme" > README.md
    git_quiet add -A
    git_quiet commit -m "첫 커밋"
    git_quiet remote add origin "$TEST_TMP/remote.git"
    git_quiet push origin main
    git config user.name test
    git config user.email test@example.com
    # 검증은 가짜: 받은 VERSION을 기록하고, VERIFY_SHOULD_FAIL이면 실패한다.
    cat > "$TEST_TMP/fake-verify.sh" <<'VERIFY'
#!/usr/bin/env bash
echo "$VERSION" >> "$TEST_TMP/verified-versions"
[[ -z "${VERIFY_SHOULD_FAIL:-}" ]]
VERIFY
    chmod +x "$TEST_TMP/fake-verify.sh"
    export KEYHUE_VERIFY_CMD="$TEST_TMP/fake-verify.sh"
}

commit_change() {
    echo "$1" >> README.md
    git_quiet commit -am "$1"
}

remote_tags() {
    git --git-dir="$TEST_TMP/remote.git" tag | tr '\n' ' '
}
