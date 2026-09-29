#!/usr/bin/env bash
# 빌드 + 단위 테스트 + 앱 번들 생성을 한 번에 검증한다.
# 로그는 .artifacts/verify/<timestamp>/ 에 남기고, TestResults → .artifacts/verify/latest 심볼릭 링크를 만든다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAMP="$(date +%Y%m%d-%H%M%S)"
DIR=".artifacts/verify/$STAMP"
mkdir -p "$DIR"
ln -sfn "$STAMP" .artifacts/verify/latest
ln -sfn .artifacts/verify/latest TestResults

step() {
    local name="$1"; shift
    echo "==> $name"
    if "$@" >"$DIR/$name.log" 2>&1; then
        echo "    ok"
    else
        echo "    FAILED — see $DIR/$name.log"
        tail -n 40 "$DIR/$name.log"
        exit 1
    fi
}

step build swift build
step test swift test
step bundle scripts/build-app.sh

grep -E "Test run with" "$DIR/test.log" || true
echo "==> all checks passed ($DIR)"
