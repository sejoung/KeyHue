# scripts/lint.sh 자체 테스트

test_flags_variable_followed_by_hangul() {
    # 검사 대상 패턴을 이 파일에 그대로 쓰면 lint가 이 파일을 잡으므로 printf로 만든다.
    printf '#!/usr/bin/env bash\nREMOTE=origin\necho "$%s로 push"\n' REMOTE > bad.sh
    SHELLCHECK=/nonexistent KEYHUE_REQUIRE_SHELLCHECK='' expect_failure "$REPO_ROOT/scripts/lint.sh" "$PWD/bad.sh"
    assert_contains "$OUT" "bad.sh:3:"
}

test_accepts_braced_variable_and_comments() {
    cat > good.sh <<'SH'
#!/usr/bin/env bash
REMOTE=origin
# 주석 속 $REMOTE로 는 검사하지 않는다
echo "${REMOTE}로 push"
SH
    SHELLCHECK=/nonexistent KEYHUE_REQUIRE_SHELLCHECK='' expect_success "$REPO_ROOT/scripts/lint.sh" "$PWD/good.sh"
}

lint_without_shellcheck() {
    SHELLCHECK=/nonexistent KEYHUE_REQUIRE_SHELLCHECK='' "$@"
}

test_reports_each_file_with_its_own_line_numbers() {
    # 줄 번호가 파일마다 1부터 다시 세어져야 어느 줄을 고칠지 알 수 있다.
    printf '#!/usr/bin/env bash\nA=1\nB=2\necho "$%s는"\n' A > first.sh
    printf '#!/usr/bin/env bash\necho "$%s로"\n' B > second.sh
    printf '#!/usr/bin/env bash\necho ok\n' > clean.sh
    lint_without_shellcheck expect_failure "$REPO_ROOT/scripts/lint.sh" "$PWD/first.sh" "$PWD/clean.sh" "$PWD/second.sh"
    assert_contains "$OUT" "first.sh:4:"
    assert_contains "$OUT" "second.sh:2:"
    assert_not_contains "$OUT" "clean.sh:"
    assert_contains "$OUT" '${NAME}처럼'
}

test_positional_parameters_and_indented_comments_are_allowed() {
    # bash 3.2에서도 $1·$#·$? 뒤 한글은 안전하다(이름이 한 글자로 끝난다).
    cat > good.sh <<'SH'
#!/usr/bin/env bash
set -- a
echo "$1로 $#개 $?번"
    # 들여쓴 주석 속 $REMOTE로 도 검사하지 않는다
SH
    lint_without_shellcheck expect_success "$REPO_ROOT/scripts/lint.sh" "$PWD/good.sh"
    expect_success /bin/bash -u good.sh
}

test_flags_variable_with_underscore_suffix_before_hangul() {
    printf '#!/usr/bin/env bash\nNAME_=x\necho "$%s은"\n' NAME_ > bad.sh
    lint_without_shellcheck expect_failure "$REPO_ROOT/scripts/lint.sh" "$PWD/bad.sh"
    assert_contains "$OUT" "bad.sh:3:"
}

test_shellcheck_failure_fails_lint() {
    mkdir -p bin
    printf '#!/bin/sh\necho "SC9999 fake warning in $*"\nexit 1\n' > bin/shellcheck
    chmod +x bin/shellcheck
    printf '#!/usr/bin/env bash\necho ok\n' > ok.sh
    SHELLCHECK="$PWD/bin/shellcheck" expect_failure "$REPO_ROOT/scripts/lint.sh" "$PWD/ok.sh"
    assert_contains "$OUT" "SC9999 fake warning"
}

test_missing_shellcheck_fails_only_when_required() {
    printf '#!/usr/bin/env bash\necho ok\n' > ok.sh
    SHELLCHECK=/nonexistent KEYHUE_REQUIRE_SHELLCHECK=1 expect_failure "$REPO_ROOT/scripts/lint.sh" "$PWD/ok.sh"
    assert_contains "$OUT" "CI에서는 ShellCheck가 필요합니다"
    lint_without_shellcheck expect_success "$REPO_ROOT/scripts/lint.sh" "$PWD/ok.sh"
    assert_contains "$OUT" "건너뜀"
}
