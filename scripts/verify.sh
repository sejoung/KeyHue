#!/usr/bin/env bash
# 빌드 + 모든 테스트 + 앱 번들 생성을 한 번에 검증한다(ADR 0022). release.sh와 CI가 쓴다.
# 로그는 .artifacts/verify/<시각>/에 남긴다. 마지막 실행은 .artifacts/verify/latest와 TestResults로 연다(scripts/artifacts.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/artifacts.sh
source scripts/artifacts.sh
DIR="$(artifacts_dir verify)"
DIR="${DIR#"$ROOT/"}"

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

site_tests() {
    if command -v node >/dev/null 2>&1; then
        node --test Tests/site/*.test.js
    else
        echo "(건너뜀: node가 없습니다)"
    fi
}

step build swift build
step test swift test                  # KeyHueCoreTests + KeyHueAppTests(통합)
step lint scripts/lint.sh             # 변수 뒤 한글 + ShellCheck(있으면)
step scripts Tests/scripts/run.sh     # release/signing/install/release-notes/lint 스크립트 테스트
step site site_tests                  # 사이트 링크·데모 로직
step bundle scripts/build-app.sh
step input-method-spike-self-check "build/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike" --self-check

grep -E "Test run with|script tests:|^ℹ (pass|fail) " "$DIR"/{test,scripts,site}.log 2>/dev/null | sed 's/^[^:]*:/    /' || true
echo "==> all checks passed ($DIR)"
