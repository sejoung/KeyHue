#!/usr/bin/env bash
# 멈춘 앱에 대한 AX 요청을 KeyHue의 대기 시간(0.25초)으로 끊을 수 있는지 잰다(ADR 0030). 로컬 전용.
#
#   Tests/perf/ax-timeout.sh [허용 초=0.5]
#
# - 이 스크립트를 실행하는 터미널에 손쉬운 사용 권한이 필요하다.
# - 직접 띄운 작은 테스트 앱만 정지(SIGSTOP)시킨다. 다른 앱은 건드리지 않는다.
# - 시간 제한을 건 요청이 허용 초를 넘으면 실패한다. 시스템 기본값으로 기다린 시간도 비교용으로 출력한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIMIT="${1:-0.5}"
TIMEOUT="$(sed -n 's/.*static let messagingTimeout: Float = \([0-9.]*\).*/\1/p' "$ROOT/Sources/KeyHueApp/Monitors/AccessibilityFocusMonitor.swift")"
WORK="$(mktemp -d)"
# 로그와 결과는 .artifacts/perf/ax-timeout/<시각>/에 남는다(마지막 실행: …/latest, TestResults).
# shellcheck source=scripts/artifacts.sh
source "$ROOT/scripts/artifacts.sh"
OUT="$(artifacts_dir perf/ax-timeout)"
exec > >(tee "$OUT/summary.log") 2>&1
trap 'if [[ -n "${APP_PID:-}" ]]; then kill -CONT "$APP_PID" 2>/dev/null || true; kill "$APP_PID" 2>/dev/null || true; fi; rm -rf "$WORK"' EXIT

[[ -n "${TIMEOUT}" ]] || { echo "error: messagingTimeout을 찾지 못했습니다" >&2; exit 1; }
swiftc -O -o "$WORK/stalled-app" "$ROOT/Tests/perf/stalled-app.swift" 2>/dev/null

"$WORK/stalled-app" window &
APP_PID=$!
disown "${APP_PID}"
sleep 1

read -r _ ERR < <("$WORK/stalled-app" probe "${APP_PID}" "${TIMEOUT}")
if [[ "${ERR}" != "0" ]]; then
    echo "error: 테스트 앱에 AX로 접근하지 못했습니다(${ERR}). 이 터미널에 손쉬운 사용 권한을 주세요." >&2
    exit 1
fi

kill -STOP "${APP_PID}"
read -r DEFAULT_WAIT _ < <("$WORK/stalled-app" probe "${APP_PID}" 0)
read -r LIMITED_WAIT LIMITED_ERR < <("$WORK/stalled-app" probe "${APP_PID}" "${TIMEOUT}")

echo "멈춘 앱에 대한 AX 요청 1회"
echo "  시스템 기본값: ${DEFAULT_WAIT}s"
echo "  KeyHue(${TIMEOUT}s): ${LIMITED_WAIT}s (error ${LIMITED_ERR})"

python3 -c "import sys; sys.exit(0 if float('${LIMITED_WAIT}') <= float('${LIMIT}') else 1)" || {
    echo "FAIL: ${LIMITED_WAIT}s > ${LIMIT}s" >&2
    exit 1
}
echo "ok"
