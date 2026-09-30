# scripts/artifacts.sh 테스트: 실행마다 폴더를 남기고, latest·TestResults가 마지막 실행을 가리키며, 오래된 기록은 정리한다

use_artifacts() {
    export KEYHUE_ARTIFACTS_ROOT="$TEST_TMP/repo/.artifacts"
    mkdir -p "$TEST_TMP/repo"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/artifacts.sh"
}

test_creates_a_timestamped_run_folder() {
    use_artifacts
    dir="$(artifacts_dir perf/demo)"
    [[ -d "$dir" ]] || fail "폴더가 없습니다: $dir"
    assert_contains "$dir" "$TEST_TMP/repo/.artifacts/perf/demo/20"
}

test_latest_links_point_to_the_last_run() {
    use_artifacts
    first="$(artifacts_dir perf/demo)"
    echo first > "$first/summary.log"
    second="$(artifacts_dir verify)"
    echo second > "$second/summary.log"
    # 종류별 latest는 그 종류의 마지막 실행, 전체 latest와 TestResults는 종류와 상관없이 마지막 실행
    assert_eq "$(cat "$TEST_TMP/repo/.artifacts/perf/demo/latest/summary.log")" "first"
    assert_eq "$(cat "$TEST_TMP/repo/.artifacts/latest/summary.log")" "second"
    assert_eq "$(cat "$TEST_TMP/repo/TestResults/summary.log")" "second"
}

test_same_second_runs_do_not_overwrite() {
    use_artifacts
    a="$(artifacts_dir perf/demo)"
    b="$(artifacts_dir perf/demo)"
    [[ "$a" != "$b" ]] || fail "같은 폴더를 다시 썼습니다: $a"
    [[ -d "$a" && -d "$b" ]] || fail "폴더가 사라졌습니다"
}

test_keeps_only_recent_runs_per_kind() {
    use_artifacts
    base="$TEST_TMP/repo/.artifacts/perf/demo"
    mkdir -p "$base/20200101-000001" "$base/20200101-000002" "$base/20200101-000003"
    mkdir -p "$TEST_TMP/repo/.artifacts/verify/20200101-000001"
    ARTIFACTS_KEEP=2 artifacts_dir perf/demo >/dev/null
    runs="$(find "$base" -mindepth 1 -maxdepth 1 -type d | sort | xargs -n1 basename | tr '\n' ' ')"
    # 새 실행 + 가장 최근 기존 실행 1개만 남는다
    assert_not_contains "$runs" "20200101-000001"
    assert_not_contains "$runs" "20200101-000002"
    assert_contains "$runs" "20200101-000003"
    # 다른 종류는 건드리지 않는다
    [[ -d "$TEST_TMP/repo/.artifacts/verify/20200101-000001" ]] || fail "다른 종류의 기록을 지웠습니다"
}
