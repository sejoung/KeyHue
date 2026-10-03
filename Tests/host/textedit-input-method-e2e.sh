#!/usr/bin/env bash
# Opt-in TextEdit test. Uses only fresh fixture documents and restores sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
[[ "${KEYHUE_TEST_TEXTEDIT:-0}" == 1 ]] || { echo "Set KEYHUE_TEST_TEXTEDIT=1 to use temporary TextEdit documents." >&2; exit 64; }
: "${KEYHUE_TEST_APP_PATH:?absolute packaged KeyHue.app path required}"
WORKER="$KEYHUE_TEST_APP_PATH/Contents/MacOS/KeyHue"
[[ -x "$WORKER" && "$KEYHUE_TEST_APP_PATH" == /* ]] || { echo "Invalid packaged app path" >&2; exit 64; }
PACKAGED_SERVICE="$KEYHUE_TEST_APP_PATH/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
INSTALLED_SERVICE="$HOME/Library/Input Methods/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
cmp -s "$PACKAGED_SERVICE" "$INSTALLED_SERVICE" || { echo "Update the installed service from this packaged app first." >&2; exit 1; }
# shellcheck source=scripts/artifacts.sh
source scripts/artifacts.sh
OUT="$(artifacts_dir input-method-textedit)"
"$WORKER" --keyhue-input-source-status > "$OUT/before.json"
ORIGINAL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["currentID"] or "")' "$OUT/before.json")"
[[ -n "$ORIGINAL" ]] || { echo "Cannot read original source" >&2; exit 1; }
UTILITY_RUNNING=0
UTILITY_APP_PATH="$KEYHUE_TEST_APP_PATH"
CLIENT_PID=""
WATCHDOG_PID=""
PLAIN=""
RICH=""
if pgrep -x KeyHue >/dev/null; then
    UTILITY_RUNNING=1
    UTILITY_APP_PATH="$(osascript -e 'POSIX path of (path to application id "io.github.sejoung.keyhue")')"
fi
restore() {
    if [[ -n "$WATCHDOG_PID" ]]; then kill "$WATCHDOG_PID" 2>/dev/null || true; fi
    if [[ -n "$CLIENT_PID" ]]; then kill "$CLIENT_PID" 2>/dev/null || true; fi
    if [[ -n "$PLAIN" && -n "$RICH" ]]; then
        osascript Tests/host/CloseTextEditFixtures.applescript "$PLAIN" "$RICH" >/dev/null 2>&1 || true
    fi
    "$WORKER" --keyhue-select-input-source "$ORIGINAL" || true
    if [[ "$UTILITY_RUNNING" == 1 ]]; then open "$UTILITY_APP_PATH"; fi
}
trap restore EXIT
if [[ "$UTILITY_RUNNING" == 1 ]]; then
    osascript -e 'tell application id "io.github.sejoung.keyhue" to quit'
    for _ in {1..50}; do
        if ! pgrep -x KeyHue >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x KeyHue >/dev/null; then echo "KeyHue did not quit" >&2; exit 1; fi
fi
STAMP="${OUT##*/}"
PLAIN="$OUT/KeyHueIMK-$STAMP-plain.txt"
RICH="$OUT/KeyHueIMK-$STAMP-rich.rtf"
: > "$PLAIN"
printf '{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 }\n' > "$RICH"
sw_vers > "$OUT/environment.log"
plutil -p "$HOME/Library/Input Methods/KeyHueInputMethodSpike.app/Contents/Info.plist" >> "$OUT/environment.log"
open -a TextEdit "$PLAIN" "$RICH"
xcrun swiftc -swift-version 6 Tests/host/TextEditNativeKey.swift -o "$OUT/TextEditNativeKey" > "$OUT/build.log" 2>&1
CLIENT_STATUS=0
PROBE_ARGUMENTS=(--both)
TEST_KIND="${KEYHUE_TEST_TEXTEDIT_KIND:-both}"
case "$TEST_KIND" in both|plain|rich) ;; *) echo "Invalid TextEdit test kind" >&2; exit 64 ;; esac
WATCHDOG_MINUTES=5
ACCEPTANCE="PASS: TextEdit actual input acceptance kind=$TEST_KIND"
if [[ "$TEST_KIND" != both ]]; then
    PROBE_ARGUMENTS=("--$TEST_KIND-only")
    WATCHDOG_MINUTES=2
fi
if [[ "${KEYHUE_TEST_TEXTEDIT_WINDOWS_ONLY:-0}" == 1 ]]; then
    PROBE_ARGUMENTS=(--windows-only)
    ACCEPTANCE='PASS: TextEdit window input acceptance'
    WATCHDOG_MINUTES=2
fi
case "${KEYHUE_TEST_TEXTEDIT_MODE_SWITCH:-menu}" in
    menu) ;;
    worker) PROBE_ARGUMENTS+=(--worker-switch) ;;
    *) echo "Invalid TextEdit mode switch method" >&2; exit 64 ;;
esac
osascript Tests/host/TextEditInputMethod.applescript "$WORKER" "$PLAIN" "$RICH" "$OUT/client.log" "$OUT/TextEditNativeKey" "${PROBE_ARGUMENTS[@]+"${PROBE_ARGUMENTS[@]}"}" > "$OUT/client-stdout.log" 2> "$OUT/client-stderr.log" &
CLIENT_PID=$!
(
    for (( minute=0; minute<WATCHDOG_MINUTES; minute++ )); do sleep 60; done
    echo 'FAIL: TextEdit test timeout' >> "$OUT/client.log"
    kill "$CLIENT_PID" 2>/dev/null || true
) &
WATCHDOG_PID=$!
wait "$CLIENT_PID" || CLIENT_STATUS=$?
CLIENT_PID=""
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=""
if [[ -f "$OUT/client.log" ]]; then cat "$OUT/client.log"; fi
"$WORKER" --keyhue-select-input-source "$ORIGINAL"
"$WORKER" --keyhue-input-source-status > "$OUT/after.json"
python3 -c 'import json,sys; before=json.load(open(sys.argv[1])); after=json.load(open(sys.argv[2])); assert before["currentID"] == after["currentID"], "original input source not restored"; assert sorted(before.get("configuredIDs") or []) == sorted(after.get("configuredIDs") or []), "configured input sources changed"' "$OUT/before.json" "$OUT/after.json"
[[ "$CLIENT_STATUS" == 0 ]] || { cat "$OUT/client-stderr.log" >&2; exit "$CLIENT_STATUS"; }
rg -Fqx "$ACCEPTANCE" "$OUT/client.log"
echo "==> results: $OUT"
