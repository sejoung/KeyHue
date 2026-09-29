#!/usr/bin/env bash
# 스크립트 테스트 실행기(ADR 0022). 외부 도구 없이 bash(3.2 포함)만으로 돈다.
#
#   Tests/scripts/run.sh                 # 전부
#   Tests/scripts/run.sh test_release    # 파일 이름에 포함된 것만
#
# 각 test_*.sh 파일의 test_로 시작하는 함수를 격리된 하위 셸과 임시 폴더에서 하나씩 실행한다.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
export REPO_ROOT
FILTER="${1:-}"
PASSED=0
FAILED=0
FAILURES=""

for file in "$HERE"/test_*.sh; do
    [[ -n "$FILTER" && "$file" != *"$FILTER"* ]] && continue
    tests="$(grep -oE '^test_[A-Za-z0-9_]+' "$file")"
    for name in $tests; do
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
        if (( status == 0 )); then
            PASSED=$((PASSED + 1))
            printf '  ✓ %s\n' "$name"
        else
            FAILED=$((FAILED + 1))
            FAILURES="$FAILURES $name"
            printf '  ✗ %s\n' "$name"
            printf '%s\n' "$output" | tail -20 | sed 's/^/      /'
        fi
    done
done

echo
echo "script tests: $PASSED passed, $FAILED failed"
if (( FAILED > 0 )); then
    echo "failed:$FAILURES"
    exit 1
fi
