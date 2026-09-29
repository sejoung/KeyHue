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
