#!/usr/bin/env bash
# 한/영 전환 → KeyHue 반영까지의 지연을 잰다(ADR 0023). 로컬 전용, 실행 중인 KeyHue가 필요하다.
#
#   Tests/perf/input-latency.sh [토글 횟수=12] [허용 ms=200]
#
# - ABC와 2-Set Korean이 켜져 있어야 한다. 입력 소스를 실제로 바꾸며, ABC로 끝난다.
# - macOS 알림 자체의 지연(기준 수신기)과 KeyHue 로그(State 카테고리)의 반영 시각을 비교한다.
# - 허용 ms를 넘는 전환이 하나라도 있으면 실패한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COUNT="${1:-12}"
LIMIT="${2:-200}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [[ -n "${LOG_PID:-}" ]] && kill "$LOG_PID" 2>/dev/null || true' EXIT

pgrep -f "KeyHue.app/Contents/MacOS/KeyHue" >/dev/null || { echo "error: KeyHue가 실행 중이 아닙니다 (scripts/install.sh)" >&2; exit 1; }
(( COUNT % 2 == 0 )) || COUNT=$((COUNT + 1))

swiftc -O -o "$WORK/toggle" "$ROOT/Tests/perf/toggle-input-source.swift" 2>/dev/null
/usr/bin/log stream --predicate 'subsystem == "KeyHue" AND category == "State"' --level debug --style compact > "$WORK/keyhue.log" 2>&1 &
LOG_PID=$!
sleep 2
"$WORK/toggle" "$COUNT" > "$WORK/toggle.txt"
sleep 1

python3 - "$WORK/toggle.txt" "$WORK/keyhue.log" "$LIMIT" <<'PY'
import datetime, re, sys
toggles = [l.split() for l in open(sys.argv[1])][1:]  # 첫 전환은 준비 단계라 제외
limit = int(sys.argv[3])
t = lambda s: datetime.datetime.strptime(s, "%H:%M:%S.%f")
logs = []
for line in open(sys.argv[2]):
    m = re.match(r"\S+ (\d\d:\d\d:\d\d\.\d{3}).*caps=\w+ source=(\S+)", line)
    if m:
        logs.append((t(m.group(1)), m.group(2)))
ref, keyhue = [], []
for time, kind, r in toggles:
    start = t(time)
    target = "ABC" if kind == "ABC" else "Korean"
    ref.append(int(r.split("=")[1][:-2]))
    hits = [d for d, src in logs if d >= start and target in src]
    keyhue.append(int((hits[0] - start).total_seconds() * 1000) if hits else 99999)
med = lambda xs: sorted(xs)[len(xs) // 2]
slow = [x for x in keyhue if x > limit]
print(f"macOS 알림: 중앙값 {med(ref)}ms, 최대 {max(ref)}ms")
print(f"KeyHue 반영: 중앙값 {med(keyhue)}ms, 최대 {max(keyhue)}ms, {limit}ms 초과 {len(slow)}/{len(keyhue)}")
sys.exit(1 if slow else 0)
PY
