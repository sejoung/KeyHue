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

# 단계 하나를 실행해 로그는 $DIR/<이름>.log, 결과 한 줄은 $DIR/<이름>.result에 남긴다.
run_step() {
    local name="$1" start="$SECONDS"; shift
    if "$@" >"$DIR/$name.log" 2>&1; then
        echo "ok ($((SECONDS - start))s)" > "$DIR/$name.result"
    else
        echo "FAILED ($((SECONDS - start))s) — see $DIR/$name.log" > "$DIR/$name.result"
    fi
}

# 결과를 출력한다. 실패면 로그 끝을 보이고 1을 돌려준다.
report() {
    local name="$1" result
    result="$(cat "$DIR/$name.result" 2>/dev/null || echo "FAILED — 결과 없음, see $DIR/$name.log")"
    echo "==> $name"
    echo "    $result"
    [[ "$result" == ok* ]] && return 0
    tail -n 40 "$DIR/$name.log"
    return 1
}

step() {
    run_step "$@"
    report "$1" || exit 1
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

# 아래 단계는 서로의 빌드 결과를 쓰지 않으므로 번들 빌드와 동시에 돈다. 스크립트 테스트는 CPU보다
# macOS가 새 실행 파일을 처음 실행할 때 하는 검사(시스템 전체에서 차례로 처리)를 기다린다.
# 시간 제한을 확인하는 swift test와는 겹치지 않게 그 뒤에 시작한다.
BACKGROUND_STEPS=(lint swift-lint code-check scripts site)
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
run_step lint scripts/lint.sh &        # 변수 뒤 한글 + ShellCheck(있으면)
# 둘 다 Tools/CodeCheck/.build를 쓰므로 차례로 돈다.
{
    run_step swift-lint scripts/swift-lint.sh                      # 파일 길이·데드 코드·참조/의존 순환(ADR 0080)
    run_step code-check swift test --package-path Tools/CodeCheck  # 순환 검사기 자체 테스트
} &
run_step scripts Tests/scripts/run.sh &   # release/signing/install/release-notes/lint 스크립트 테스트
run_step site site_tests &                # 사이트 링크·데모 로직

step bundle scripts/build-app.sh
step input-method-spike-self-check "build/KeyHue.app/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike" --self-check

wait
FAILED=0
for name in "${BACKGROUND_STEPS[@]}"; do report "$name" || FAILED=1; done
(( FAILED == 0 )) || exit 1

grep -E "Test run with|script tests:|^ℹ (pass|fail) " "$DIR"/{test,scripts,site}.log 2>/dev/null | sed 's/^[^:]*:/    /' || true
echo "==> all checks passed ($DIR)"
