#!/usr/bin/env bash
# 셸 스크립트 검사(ADR 0022)
#
# 1. ShellCheck: 설치돼 있으면 실행한다. KEYHUE_REQUIRE_SHELLCHECK=1(CI lint 작업)이면 없을 때 실패한다.
# 2. 변수 바로 뒤 한글: macOS 기본 bash(3.2)는 "$REMOTE로"의 '로' 첫 바이트까지 변수 이름으로 읽어
#    unbound variable 오류를 낸다(실제로 겪은 버그). "${REMOTE}로"처럼 중괄호를 써야 한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 인자로 파일을 주면 그것만 검사한다(lint 자체 테스트용).
if (( $# > 0 )); then
    FILES=("$@")
else
    FILES=(scripts/*.sh Tests/scripts/*.sh Tests/ci/*.sh)
fi
STATUS=0

echo "==> 변수 뒤 한글 검사"
if perl -CSD -ne '
    next if /^\s*#/;
    if (/\$[A-Za-z_][A-Za-z_0-9]*(?=[^\x00-\x7F])/) { print "$ARGV:$.: $_"; $bad = 1 }
    close ARGV if eof;
    END { exit($bad ? 1 : 0) }
' "${FILES[@]}"; then
    echo "    ok"
else
    echo "error: 위 줄에서 변수를 \${NAME}처럼 중괄호로 감싸세요" >&2
    STATUS=1
fi

echo "==> ShellCheck"
SHELLCHECK="${SHELLCHECK:-shellcheck}"
if command -v "$SHELLCHECK" >/dev/null 2>&1; then
    if "$SHELLCHECK" --shell=bash --severity=warning "${FILES[@]}"; then
        echo "    ok"
    else
        STATUS=1
    fi
elif [[ -n "${KEYHUE_REQUIRE_SHELLCHECK:-}" ]]; then
    echo "error: CI에서는 ShellCheck가 필요합니다" >&2
    STATUS=1
else
    echo "    (건너뜀: shellcheck가 없습니다. brew install shellcheck)"
fi

exit "$STATUS"
