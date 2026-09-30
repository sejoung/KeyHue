#!/usr/bin/env bash
# KeyHue보다 나중에 실행된 앱에서도 창 전환을 감지하는지 확인한다(ADR 0033). 로컬 전용.
#
#   Tests/perf/window-switch-after-launch.sh [회수=3]
#
# - 실행 중인 KeyHue가 필요하고, "창을 바꿀 때"가 "그대로 두기"가 아니어야 한다.
# - 이 터미널에 손쉬운 사용 권한이 필요하다(측정용 앱의 창을 AX로 앞으로 올린다).
# - 매 회 창 두 개짜리 측정용 앱을 새로 실행하고 곧바로 창을 두 번 바꾼다. 그동안 화면 포커스가 옮겨 간다.
# - KeyHue 로그에 창 전환이 두 번 모두 찍히지 않은 회차가 있으면 실패한다.
# - 측정용 앱이 맨 앞에 오지 못하면(화면 잠금 등) 멈춘다. 측정하는 동안 키보드·마우스를 쓰지 않는다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOMAIN="io.github.sejoung.keyhue"
PERF_ID="${DOMAIN}.perf.windows"
COUNT="${1:-3}"
WORK="$(mktemp -d)"
LOG_PID=""
cleanup() {
    [[ -n "${LOG_PID}" ]] && kill "${LOG_PID}" 2>/dev/null || true
    pkill -f "KeyHuePerfWindows.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

front_bundle_id() {
    lsappinfo info -only bundleid "$(lsappinfo front)" | sed -n 's/.*="\(.*\)"/\1/p'
}

pgrep -f "KeyHue.app/Contents/MacOS/KeyHue" >/dev/null || { echo "error: KeyHue가 실행 중이 아닙니다 (scripts/install.sh)" >&2; exit 1; }
if [[ "$(defaults read "${DOMAIN}" onWindowSwitch 2>/dev/null || echo keep)" == "keep" ]]; then
    echo "error: KeyHue 설정에서 \"창을 바꿀 때\"를 켜 주세요" >&2
    exit 1
fi

swiftc -O -o "$WORK/window-switch" "$ROOT/Tests/perf/window-switch.swift" 2>/dev/null
APP="$WORK/KeyHuePerfWindows.app"
mkdir -p "$APP/Contents/MacOS"
cp "$WORK/window-switch" "$APP/Contents/MacOS/KeyHuePerfWindows"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${PERF_ID}</string>
<key>CFBundleName</key><string>KeyHuePerfWindows</string>
<key>CFBundleExecutable</key><string>KeyHuePerfWindows</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign -s - -f "$APP" 2>/dev/null

failures=0
for ((i = 1; i <= COUNT; i++)); do
    # log stream은 파일로 쓸 때 버퍼링하므로, 매 회 종료(SIGINT)해서 비운 뒤 읽는다.
    /usr/bin/log stream --predicate 'subsystem == "KeyHue"' --level debug --style compact > "$WORK/keyhue.log" 2>&1 &
    LOG_PID=$!
    sleep 1.5
    open -n "$APP"
    pid=""
    for _ in $(seq 50); do
        pid="$(pgrep -f "KeyHuePerfWindows.app/Contents/MacOS" || true)"
        [[ -n "${pid}" ]] && break
        sleep 0.1
    done
    [[ -n "${pid}" ]] || { echo "error: 측정용 앱이 실행되지 않았습니다" >&2; exit 1; }
    for _ in $(seq 30); do
        [[ "$(front_bundle_id)" == "${PERF_ID}" ]] && break
        sleep 0.1
    done
    front="$(front_bundle_id)"
    if [[ "${front}" != "${PERF_ID}" ]]; then
        echo "error: 측정용 앱이 맨 앞에 오지 않았습니다(지금 맨 앞: ${front}). 화면 잠금을 풀고 다시 실행하세요" >&2
        exit 1
    fi
    sleep 1 # 앱을 띄우고 창을 바꾸기까지의 짧은 시간. KeyHue의 재시도(최대 약 3초) 중 앞부분이다
    "$WORK/window-switch" switch "${pid}"
    sleep 0.5
    kill -INT "${LOG_PID}"; wait "${LOG_PID}" 2>/dev/null || true; LOG_PID=""
    kill "${pid}"; sleep 0.5
    detected="$(grep -c "window switched within ${PERF_ID}" "$WORK/keyhue.log" || true)"
    echo "#${i}: 창 전환 2번 중 ${detected}번 감지"
    if (( detected < 2 )); then
        failures=$((failures + 1))
        grep "KeyHue\[" "$WORK/keyhue.log" | sed 's/^/    /' || true
    fi
done

if (( failures > 0 )); then
    echo "FAIL: ${COUNT}회 중 ${failures}회 창 전환을 놓침"
    exit 1
fi
echo "ok"
