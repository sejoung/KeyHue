#!/usr/bin/env bash
# 앱 전환 → KeyHue가 입력 소스를 바꾸기까지의 지연과 깜빡임을 잰다(ADR 0031). 로컬 전용.
#
#   Tests/perf/app-switch-latency.sh [회수=20] [허용 중앙값 ms=100]
#   Tests/perf/app-switch-latency.sh race [회수=20] [지연 ms...]   # KeyHue 없이 시스템 덮어쓰기만 재현
#
# - 측정용 앱 두 개(KeyHuePerfA/B)를 띄워 번갈아 활성화한다. 그동안 화면 포커스가 오간다. 키 입력은 보내지 않는다.
# - ABC와 2-Set Korean이 켜져 있어야 한다.
# - e2e: 실행 중인 KeyHue가 필요하다. 측정하는 동안만 "앱을 바꿀 때"를 "ABC로 전환"으로 바꾸고, 끝나면 설정을 되돌린다.
#   실패(ABC가 안 됨)나 깜빡임이 있거나 중앙값이 허용치를 넘으면 실패한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOMAIN="io.github.sejoung.keyhue"
WORK="$(mktemp -d)"
MODE="e2e"
if [[ "${1:-}" == "race" ]]; then MODE="race"; shift; fi
COUNT="${1:-20}"
# 로그와 결과는 .artifacts/perf/app-switch-latency/<시각>/(race 모드는 …/app-switch-race/)에 남는다(마지막 실행: …/latest, TestResults).
# shellcheck source=scripts/artifacts.sh
source "$ROOT/scripts/artifacts.sh"
if [[ "${MODE}" == "race" ]]; then OUT="$(artifacts_dir perf/app-switch-race)"; else OUT="$(artifacts_dir perf/app-switch-latency)"; fi
exec > >(tee "$OUT/summary.log") 2>&1

restore() {
    keyhue_log_save "$OUT" "${KEYHUE_LOG_MARK:-}"
    if [[ -f "$WORK/defaults.plist" ]]; then
        osascript -e "quit app id \"${DOMAIN}\"" 2>/dev/null || true
        sleep 1
        defaults import "${DOMAIN}" "$WORK/defaults.plist"
        open -b "${DOMAIN}"
    fi
    rm -rf "$WORK"
}
trap restore EXIT

KEYHUE_LOG_MARK="$(keyhue_log_mark)"
swiftc -O -o "$WORK/app-switch" "$ROOT/Tests/perf/app-switch.swift" 2>/dev/null
for name in A B; do
    contents="$WORK/KeyHuePerf${name}.app/Contents"
    mkdir -p "$contents/MacOS"
    cp "$WORK/app-switch" "$contents/MacOS/KeyHuePerf${name}"
    cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${DOMAIN}.perf.${name}</string>
<key>CFBundleName</key><string>KeyHuePerf${name}</string>
<key>CFBundleExecutable</key><string>KeyHuePerf${name}</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    codesign -s - -f "$WORK/KeyHuePerf${name}.app" 2>/dev/null
done
APPS=("$WORK/KeyHuePerfA.app" "$WORK/KeyHuePerfB.app")

if [[ "${MODE}" == "race" ]]; then
    shift || true
    DELAYS=("$@")
    [[ ${#DELAYS[@]} -gt 0 ]] || DELAYS=(0 10 20 30 40 60)
    if pgrep -f "KeyHue.app/Contents/MacOS/KeyHue" >/dev/null; then
        echo "error: KeyHue를 종료한 뒤 실행하세요(KeyHue도 전환하면 측정이 섞입니다)" >&2
        exit 1
    fi
    "$WORK/app-switch" race "${APPS[@]}" "${COUNT}" "${DELAYS[@]}"
    exit 0
fi

LIMIT="${2:-100}"
pgrep -f "KeyHue.app/Contents/MacOS/KeyHue" >/dev/null || { echo "error: KeyHue가 실행 중이 아닙니다 (scripts/install.sh)" >&2; exit 1; }
defaults export "${DOMAIN}" "$WORK/defaults.plist"
osascript -e "quit app id \"${DOMAIN}\""
sleep 1
defaults write "${DOMAIN}" onAppSwitch switchToDefault
open -b "${DOMAIN}"
sleep 3

"$WORK/app-switch" e2e "${APPS[@]}" "${COUNT}" > "$OUT/result.txt"
cat "$OUT/result.txt"
python3 - "$OUT/result.txt" "${LIMIT}" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"failures=(\d+) flickers=(\d+)\s+median=(\d+)ms", text)
if not m:
    sys.exit("error: 결과를 읽지 못했습니다")
failures, flickers, median = map(int, m.groups())
limit = int(sys.argv[2])
if failures or flickers or median > limit:
    sys.exit(f"FAIL: failures={failures} flickers={flickers} median={median}ms (허용 {limit}ms)")
print("ok")
PY
