#!/usr/bin/env bash
# 스크립트 테스트 실행기(ADR 0022). 외부 도구 없이 bash(3.2 포함)만으로 돈다.
#
#   Tests/scripts/run.sh                 # 전부
#   Tests/scripts/run.sh test_release    # 파일 이름에 포함된 것만
#   KEYHUE_TEST_JOBS=1 Tests/scripts/run.sh   # 하나씩(기본: CPU 수만큼 동시에)
#
# 각 test_*.sh 파일의 test_로 시작하는 함수를 격리된 하위 셸과 임시 폴더에서 하나씩 실행한다.
# 테스트끼리 공유하는 상태가 없으므로 동시에 돌리고, 결과는 파일 순서대로 출력한다.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
export REPO_ROOT

# 테스트 하나: run.sh --one <file> <name> <result>. 첫 줄은 종료 상태, 나머지는 출력.
if [[ "${1:-}" == --one ]]; then
    file="$2" name="$3" result="$4"
    workdir="$(mktemp -d)"
    output="$( (
        cd "$workdir" || exit 1
        export TEST_TMP="$workdir"
        # shellcheck source=/dev/null
        source "$HERE/lib.sh"
        # shellcheck source=/dev/null
        source "$file"
        set -e
        "$name"
    ) 2>&1 )"
    status=$?
    rm -rf "$workdir"
    printf '%s\n%s\n' "$status" "$output" > "$result"
    exit 0
fi

FILTER="${1:-}"
JOBS="${KEYHUE_TEST_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
RESULTS="$(mktemp -d)"
STUB_CACHE="$(mktemp -d)"
export STUB_CACHE
trap 'rm -rf "$RESULTS" "$RESULTS.jobs" "$STUB_CACHE"' EXIT
PASSED=0
FAILED=0
FAILURES=""

index=0
for file in "$HERE"/test_*.sh; do
    [[ -n "$FILTER" && "$file" != *"$FILTER"* ]] && continue
    for name in $(grep -oE '^test_[A-Za-z0-9_]+' "$file"); do
        index=$((index + 1))
        result="$RESULTS/$(printf '%04d' "$index")-$name"
        # 결과를 남기지 못하고 끝난 테스트도 실패로 보이게 한다.
        printf 'missing\n결과 없이 끝났습니다\n' > "$result"
        printf '%s\0%s\0%s\0' "$file" "$name" "$result"
    done
done > "$RESULTS.jobs"
xargs -0 -n 3 -P "$JOBS" "$HERE/run.sh" --one < "$RESULTS.jobs"
rm -f "$RESULTS.jobs"

for result in "$RESULTS"/*; do
    [[ -e "$result" ]] || continue
    name="${result##*/}"
    name="${name#*-}"
    status="$(head -1 "$result")"
    if [[ "$status" == 0 ]]; then
        PASSED=$((PASSED + 1))
        printf '  ✓ %s\n' "$name"
    else
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES $name"
        printf '  ✗ %s\n' "$name"
        tail -n +2 "$result" | tail -20 | sed 's/^/      /'
    fi
done

echo
echo "script tests: $PASSED passed, $FAILED failed"
if (( FAILED > 0 )); then
    echo "failed:$FAILURES"
    exit 1
fi
