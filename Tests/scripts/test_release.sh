# scripts/release.sh (ADR 0017)

test_patch_bumps_verifies_commits_tags_and_pushes() {
    make_release_repo 0.1.0
    commit_change "기능 추가"
    expect_success scripts/release.sh patch --yes
    assert_eq "$(cat VERSION)" "0.1.1"
    assert_eq "$(cat "$TEST_TMP/verified-versions")" "0.1.1" "검증은 새 버전으로 돌아야 한다"
    assert_eq "$(git log -1 --pretty=%s)" "릴리즈 v0.1.1"
    assert_eq "$(remote_tags)" "v0.1.1 "
    assert_eq "$(git --git-dir="$TEST_TMP/remote.git" show main:VERSION)" "0.1.1"
    assert_contains "$(git tag -l --format='%(contents)' v0.1.1)" "- 기능 추가" "태그 메시지에 변경 내역"
}

test_minor_and_major_reset_lower_parts() {
    make_release_repo 1.4.7
    commit_change "a"
    expect_success scripts/release.sh minor --yes --no-push
    assert_eq "$(cat VERSION)" "1.5.0"
    commit_change "b"
    expect_success scripts/release.sh major --yes --no-push
    assert_eq "$(cat VERSION)" "2.0.0"
}

test_explicit_version_must_be_greater() {
    make_release_repo 1.2.3
    commit_change "a"
    expect_failure scripts/release.sh 1.2.3 --yes
    assert_contains "$OUT" "보다 커야"
    expect_failure scripts/release.sh 0.9.0 --yes
    expect_success scripts/release.sh 1.10.0 --yes --no-push
    assert_eq "$(cat VERSION)" "1.10.0"
}

test_dry_run_changes_nothing() {
    make_release_repo 0.1.0
    commit_change "a"
    echo "dirty" > untracked.txt # dry-run은 더러운 작업 트리도 허용
    expect_success scripts/release.sh patch --dry-run
    assert_contains "$OUT" "dry-run 완료"
    assert_eq "$(cat VERSION)" "0.1.0"
    assert_eq "$(git tag)" ""
    assert_eq "$(cat "$TEST_TMP/verified-versions")" "0.1.1" "dry-run도 검증은 한다"
}

test_verify_failure_changes_nothing() {
    make_release_repo 0.1.0
    commit_change "a"
    export VERIFY_SHOULD_FAIL=1
    expect_failure scripts/release.sh patch --yes
    assert_eq "$(cat VERSION)" "0.1.0"
    assert_eq "$(git tag)" ""
    assert_eq "$(remote_tags)" ""
    assert_eq "$(git log -1 --pretty=%s)" "a"
}

test_rejects_dirty_tree() {
    make_release_repo
    commit_change "a"
    echo x > junk.txt
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "커밋하지 않은 변경"
}

test_rejects_other_branch() {
    make_release_repo
    git_quiet checkout -b feature
    commit_change "a"
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "'main' 브랜치에서만"
}

test_rejects_existing_tag() {
    make_release_repo 0.1.0
    commit_change "a"
    git_quiet tag v0.1.1
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "태그 v0.1.1가 이미 있습니다"
}

test_rejects_when_behind_remote() {
    make_release_repo
    git_quiet clone "$TEST_TMP/remote.git" "$TEST_TMP/other"
    (cd "$TEST_TMP/other" && echo y >> README.md && git_quiet commit -am "다른 사람" && git_quiet push origin main)
    commit_change "a"
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "뒤처져"
}

test_rejects_when_nothing_changed_since_last_tag() {
    make_release_repo 0.1.0
    commit_change "a"
    expect_success scripts/release.sh patch --yes
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "이후 커밋이 없습니다"
}

test_no_push_keeps_remote_untouched() {
    make_release_repo
    commit_change "a"
    expect_success scripts/release.sh patch --yes --no-push
    assert_eq "$(git tag)" "v0.1.1"
    assert_eq "$(remote_tags)" ""
    assert_contains "$OUT" "push 생략"
}

test_requires_remote_unless_no_push() {
    make_release_repo
    git remote remove origin
    commit_change "a"
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "remote 'origin'가 없습니다"
    expect_success scripts/release.sh patch --yes --no-push
}

test_rejects_bad_arguments_and_version_file() {
    make_release_repo
    expect_failure scripts/release.sh banana
    assert_contains "$OUT" "unknown argument"
    expect_failure scripts/release.sh
    echo "v1" > VERSION && git_quiet commit -am "bad"
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "X.Y.Z가 아닙니다"
}

test_non_interactive_run_requires_yes() {
    make_release_repo
    commit_change "a"
    expect_failure scripts/release.sh patch < /dev/null
    assert_contains "$OUT" "--yes"
}

# 아무것도 바뀌지 않았는지: VERSION, 로컬·원격 태그, 검증 실행 여부
assert_nothing_released() {
    assert_eq "$(cat VERSION)" "${1:-0.1.0}"
    assert_eq "$(git tag)" "${2:-}"
    assert_eq "$(remote_tags)" "${3:-}"
    [[ ! -e "$TEST_TMP/verified-versions" ]] || fail "검증까지 진행했습니다"
}

test_rejects_missing_version_file() {
    make_release_repo
    git_quiet rm VERSION
    git_quiet commit -m "VERSION 삭제"
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "VERSION 파일이 없습니다"
    assert_eq "$(remote_tags)" ""
}

test_rejects_non_semver_explicit_versions_before_verifying() {
    make_release_repo
    commit_change "a"
    for version in v0.2.0 0.2 2; do
        expect_failure scripts/release.sh "$version" --yes
        assert_contains "$OUT" "unknown argument: $version"
    done
    for version in 0.2.0-beta.1 0.2.0+build.5 0.2.0.1 0.2.3x; do
        expect_failure scripts/release.sh "$version" --yes
        assert_contains "$OUT" "X.Y.Z가 아닙니다: '$version'"
    done
    assert_nothing_released
}

test_accepts_version_file_with_crlf_and_writes_clean_version() {
    make_release_repo
    git config core.autocrlf false # 사용자 전역 설정과 무관하게 CRLF를 그대로 커밋한다
    printf '0.1.0\r\n' > VERSION
    git_quiet commit -am "CRLF VERSION"
    expect_success scripts/release.sh patch --yes --no-push
    assert_eq "$(cat VERSION)" "0.1.1"
    assert_eq "$(od -An -c VERSION | tr -d ' \n')" '0.1.1\n'
}

test_rejects_tag_that_exists_only_on_remote() {
    make_release_repo
    git_quiet clone "$TEST_TMP/remote.git" "$TEST_TMP/other"
    (cd "$TEST_TMP/other" && git_quiet tag v0.1.1 && git_quiet push origin v0.1.1)
    commit_change "a"
    git tag -d v0.1.1 >/dev/null 2>&1 || true
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "태그 v0.1.1가 origin에 이미 있습니다"
    assert_eq "$(cat VERSION)" "0.1.0"
    [[ ! -e "$TEST_TMP/verified-versions" ]] || fail "검증까지 진행했습니다"
}

test_rejects_detached_head() {
    make_release_repo
    commit_change "a"
    git_quiet checkout --detach
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "detached HEAD"
    assert_nothing_released
}

test_release_branch_can_be_overridden() {
    make_release_repo
    git_quiet checkout -b release
    commit_change "릴리즈 브랜치 수정"
    RELEASE_BRANCH=release expect_success scripts/release.sh patch --yes
    assert_eq "$(git --git-dir="$TEST_TMP/remote.git" show release:VERSION)" "0.1.1"
    assert_eq "$(git --git-dir="$TEST_TMP/remote.git" show main:VERSION)" "0.1.0" "main은 그대로"
    assert_eq "$(remote_tags)" "v0.1.1 "
    # 기본 브랜치(main)에서는 거부한다
    git_quiet checkout main
    commit_change "b"
    RELEASE_BRANCH=release expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "'release' 브랜치에서만"
}

test_changes_skip_merge_commits_and_keep_special_characters_literally() {
    make_release_repo
    git_quiet checkout -b feature
    # shellcheck disable=SC2016 # 셸 문법을 글자 그대로 커밋 제목에 넣는다
    local subject='한글 "따옴표" $HOME `id` $(touch pwned) 50%'
    echo f >> README.md
    git_quiet commit -am "$subject"
    git_quiet checkout main
    git_quiet merge --no-ff -m "Merge branch 'feature'" feature
    expect_success scripts/release.sh patch --yes --no-push
    local message
    message="$(git tag -l --format='%(contents)' v0.1.1)"
    assert_contains "$message" "- $subject"
    assert_not_contains "$message" "Merge branch"
    [[ ! -e pwned && ! -e scripts/pwned ]] || fail "커밋 제목을 셸로 실행했습니다"
}

test_rejected_push_keeps_local_release_and_leaves_remote_untouched() {
    make_release_repo
    printf '#!/bin/sh\necho "rejected by hook" >&2\nexit 1\n' > "$TEST_TMP/remote.git/hooks/pre-receive"
    chmod +x "$TEST_TMP/remote.git/hooks/pre-receive"
    commit_change "a"
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "push에 실패했습니다"
    assert_contains "$OUT" "git push --atomic origin HEAD:refs/heads/main refs/tags/v0.1.1"
    assert_eq "$(git tag)" "v0.1.1" "로컬 태그는 남는다"
    assert_eq "$(git log -1 --pretty=%s)" "릴리즈 v0.1.1"
    assert_eq "$(remote_tags)" ""
    assert_eq "$(git --git-dir="$TEST_TMP/remote.git" show main:VERSION)" "0.1.0"
}

test_first_release_to_an_empty_remote_creates_branch_and_tag() {
    make_release_repo
    git_quiet init --bare "$TEST_TMP/empty.git"
    git_quiet remote add empty "$TEST_TMP/empty.git"
    RELEASE_REMOTE=empty expect_success scripts/release.sh patch --yes
    assert_eq "$(git --git-dir="$TEST_TMP/empty.git" show main:VERSION)" "0.1.1"
    assert_eq "$(git --git-dir="$TEST_TMP/empty.git" tag)" "v0.1.1"
    # 첫 릴리즈의 변경 내역은 처음부터의 커밋
    assert_contains "$(git tag -l --format='%(contents)' v0.1.1)" "- 첫 커밋"
}

test_dry_run_without_remote_is_allowed() {
    make_release_repo
    git remote remove origin
    commit_change "a"
    expect_success scripts/release.sh patch --dry-run
    assert_contains "$OUT" "dry-run 완료"
    assert_eq "$(git tag)" ""
}

test_help_prints_usage_without_releasing() {
    make_release_repo
    expect_success scripts/release.sh --help
    assert_contains "$OUT" "scripts/release.sh patch"
    assert_contains "$OUT" "--dry-run"
    assert_nothing_released
}

test_rejects_leading_zeros_in_versions() {
    make_release_repo
    commit_change "a"
    for version in 01.3.0 0.02.0 0.1.01 00.2.0; do
        expect_failure scripts/release.sh "$version" --yes
        assert_contains "$OUT" "X.Y.Z가 아닙니다: '$version'"
    done
    assert_nothing_released
    # 0 자체와 10처럼 0으로 끝나는 숫자는 정상이다.
    printf '0.9.0\n' > VERSION && git_quiet commit -am "0.9.0"
    expect_success scripts/release.sh 0.10.0 --yes --no-push
    assert_eq "$(cat VERSION)" "0.10.0"
}

test_rejects_leading_zeros_in_the_version_file() {
    make_release_repo
    printf '0.01.0\n' > VERSION && git_quiet commit -am "bad"
    expect_failure scripts/release.sh patch --yes
    assert_contains "$OUT" "VERSION 파일 형식이 X.Y.Z가 아닙니다"
}

test_rejects_more_than_one_version_argument() {
    make_release_repo
    commit_change "a"
    for args in "major patch" "patch patch" "minor 0.3.0" "0.2.0 0.3.0"; do
        # shellcheck disable=SC2086 # 인자 두 개로 나눠 넘긴다
        expect_failure scripts/release.sh $args --yes
        assert_contains "$OUT" "버전은 하나만"
    done
    assert_nothing_released
}
