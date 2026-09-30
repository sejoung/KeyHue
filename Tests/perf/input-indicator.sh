#!/usr/bin/env bash
# macOS 입력 소스 표시(커서 옆 한/A 배지)를 켜고 끄는 설정이 실행 중인 앱에 바로 적용되는지 캡처로 확인한다(ADR 0034). 로컬 전용.
#
#   Tests/perf/input-indicator.sh [회수=2]
#
# - ABC와 2-Set Korean이 켜져 있어야 하고, 터미널에 화면 기록 권한이 필요하다(캡처).
# - 측정용 앱 하나를 띄워 둔 채 macOS 설정(TSMLanguageIndicatorEnabled)을 표시 → 숨김으로 바꾸고,
#   그때마다 입력 소스를 바꿔 **측정용 앱 창만** 캡처한다. 끝나면 원래 설정과 입력 소스로 되돌린다.
# - 표시일 때 배지가 보이지 않거나, 숨김일 때 보이면 실패한다.
# - 캡처와 결과는 .artifacts/perf/input-indicator/<시각>/에 남는다(마지막 실행: …/latest, TestResults).
# - 측정하는 동안 화면 포커스가 옮겨 간다. 키보드·마우스를 쓰지 않는다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PERF_ID="io.github.sejoung.keyhue.perf.indicator"
KEY="TSMLanguageIndicatorEnabled"
COUNT="${1:-2}"
# 배지 픽셀 기준. 실측: 배지가 있으면 약 1,900, 없으면 커서만 약 100.
THRESHOLD=500
WORK="$(mktemp -d)"
# shellcheck source=scripts/artifacts.sh
source "$ROOT/scripts/artifacts.sh"
OUT="$(artifacts_dir perf/input-indicator)"
exec > >(tee "$OUT/summary.log") 2>&1

ORIGINAL="$(defaults read -g "${KEY}" 2>/dev/null || echo absent)"
restore() {
    if [[ "${ORIGINAL}" == "absent" ]]; then
        defaults delete -g "${KEY}" 2>/dev/null || true
    else
        # defaults read는 불리언을 0/1로 출력한다. 원래 타입(불리언)으로 되돌린다.
        if [[ "${ORIGINAL}" == "0" ]]; then
            defaults write -g "${KEY}" -bool false
        else
            defaults write -g "${KEY}" -bool true
        fi
    fi
    pkill -f "KeyHuePerfIndicator.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$WORK"
}
trap restore EXIT

swiftc -O -o "$WORK/input-indicator" "$ROOT/Tests/perf/input-indicator.swift" 2>/dev/null
APP="$WORK/KeyHuePerfIndicator.app"
mkdir -p "$APP/Contents/MacOS"
cp "$WORK/input-indicator" "$APP/Contents/MacOS/KeyHuePerfIndicator"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${PERF_ID}</string>
<key>CFBundleName</key><string>KeyHuePerfIndicator</string>
<key>CFBundleExecutable</key><string>KeyHuePerfIndicator</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign -s - -f "$APP" 2>/dev/null

echo "원래 설정: ${KEY} = ${ORIGINAL}"
# 측정용 앱은 한 번만 띄운다. 설정을 바꾼 뒤 다시 실행하지 않아도 적용되는지 보려는 것이다.
open -n "$APP"

failures=0
shoot() {
    local label="$1" expect="$2" file pixels
    echo "--- ${label}"
    "$WORK/input-indicator" shoot "$OUT/${label}" "${COUNT}" > "$WORK/shots.txt" || { cat "$WORK/shots.txt"; exit 1; }
    while read -r file pixels; do
        local seen="없음"
        (( pixels >= THRESHOLD )) && seen="있음"
        echo "  $(basename "${file}"): 배지 ${seen} (${pixels}px)"
        if [[ "${expect}" == "shown" && "${seen}" == "없음" ]] || [[ "${expect}" == "hidden" && "${seen}" == "있음" ]]; then
            failures=$((failures + 1))
        fi
    done < "$WORK/shots.txt"
}

defaults delete -g "${KEY}" 2>/dev/null || true
sleep 1
shoot shown shown
defaults write -g "${KEY}" -bool false
sleep 1
shoot hidden hidden

echo "캡처: ${OUT}"
if (( failures > 0 )); then
    echo "FAIL: 예상과 다른 캡처 ${failures}장"
    exit 1
fi
echo "ok"
