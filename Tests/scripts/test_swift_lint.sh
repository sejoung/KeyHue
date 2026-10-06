# scripts/swift-lint.sh 자체 테스트. 실제 도구 대신 가짜 실행 파일을 쓴다(빌드하지 않는다).

fake_tool() {
    # fake_tool <이름> <종료 코드> [출력]
    mkdir -p bin
    printf '#!/bin/sh\necho "%s"\nexit %s\n' "${3:-}" "$2" > "bin/$1"
    chmod +x "bin/$1"
}

without_swift_tools() {
    SWIFTLINT=/nonexistent PERIPHERY=/nonexistent KEYHUE_REQUIRE_SWIFT_LINT='' "$@"
}

test_missing_tools_are_skipped_locally() {
    fake_tool code-check 0 "code-check: ok"
    CODE_CHECK="$PWD/bin/code-check" without_swift_tools expect_success "$REPO_ROOT/scripts/swift-lint.sh"
    assert_contains "$OUT" "건너뜀: swiftlint"
    assert_contains "$OUT" "건너뜀: periphery"
    assert_contains "$OUT" "code-check: ok"
}

test_missing_tools_fail_when_required() {
    fake_tool code-check 0
    CODE_CHECK="$PWD/bin/code-check" SWIFTLINT=/nonexistent PERIPHERY=/nonexistent KEYHUE_REQUIRE_SWIFT_LINT=1 \
        expect_failure "$REPO_ROOT/scripts/swift-lint.sh"
    assert_contains "$OUT" "CI에서는 swiftlint이(가) 필요합니다"
    assert_contains "$OUT" "CI에서는 periphery이(가) 필요합니다"
}

test_swiftlint_errors_fail_the_check() {
    fake_tool swiftlint 1 "Big.swift:401:1: error: File Length Violation"
    fake_tool code-check 0
    CODE_CHECK="$PWD/bin/code-check" SWIFTLINT="$PWD/bin/swiftlint" PERIPHERY=/nonexistent KEYHUE_REQUIRE_SWIFT_LINT='' \
        expect_failure "$REPO_ROOT/scripts/swift-lint.sh"
    assert_contains "$OUT" "File Length Violation"
}

test_cycle_findings_fail_the_check_and_name_every_module() {
    mkdir -p bin
    # 받은 인자를 그대로 보여 주고 실패한다.
    printf '#!/bin/sh\necho "args: $*"\necho "A.swift:1:1: error: types depend on each other"\nexit 1\n' > bin/code-check
    chmod +x bin/code-check
    CODE_CHECK="$PWD/bin/code-check" without_swift_tools expect_failure "$REPO_ROOT/scripts/swift-lint.sh"
    assert_contains "$OUT" "types depend on each other"
    assert_contains "$OUT" "KeyHueCore=Sources/KeyHueCore/"
    assert_contains "$OUT" "KeyHueApp=Sources/KeyHueApp/"
    assert_contains "$OUT" "KeyHueInputMethodSpikeCore=Tools/InputMethodSpike/Core"
    assert_contains "$OUT" "KeyHueInputMethodSpike=Tools/InputMethodSpike/App"
}
