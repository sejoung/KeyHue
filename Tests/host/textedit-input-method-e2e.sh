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
IMK_LOG_FILE="$HOME/Library/Logs/KeyHue/KeyHueInputMethod.log"
IMK_LOG_MARK="$(KEYHUE_LOG_FILE="$IMK_LOG_FILE" keyhue_log_mark)"
"$WORKER" --keyhue-input-source-status > "$OUT/before.json"
ORIGINAL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["currentID"] or "")' "$OUT/before.json")"
[[ -n "$ORIGINAL" ]] || { echo "Cannot read original source" >&2; exit 1; }
UTILITY_RUNNING=0
UTILITY_APP_PATH="$KEYHUE_TEST_APP_PATH"
CLIENT_PID=""
WATCHDOG_PID=""
PLAIN=""
RICH=""
SENDER_APP=""
TEST_LOG_SAVED=0
IME_DOMAIN=io.github.sejoung.keyhue.inputmethod.spike
OVERRIDE_SET=0
if pgrep -x KeyHue >/dev/null; then
    UTILITY_RUNNING=1
    UTILITY_APP_PATH="$(osascript -e 'POSIX path of (path to application id "io.github.sejoung.keyhue")')"
fi
stop_sender() {
    if [[ -n "$SENDER_APP" && -f "$OUT/source-sender-0.log" ]]; then
        local sender_pid sender_command
        sender_pid="$(python3 -c 'import re,sys; match=re.search(r"pid=(\d+)",open(sys.argv[1]).read()); print(match[1] if match else "")' "$OUT/source-sender-0.log" 2>/dev/null || true)"
        if [[ "$sender_pid" =~ ^[0-9]+$ ]]; then
            sender_command="$(ps -p "$sender_pid" -o comm= || true)"
            if [[ "$sender_command" == "$SENDER_APP/Contents/MacOS/TextEditSourceSender" ]]; then
                kill "$sender_pid" 2>/dev/null || true
                for _ in {1..20}; do
                    if ! kill -0 "$sender_pid" 2>/dev/null; then break; fi
                    sleep 0.05
                done
            fi
        fi
    fi
}
restore() {
    if [[ -n "$WATCHDOG_PID" ]]; then kill "$WATCHDOG_PID" 2>/dev/null || true; fi
    if [[ -n "$CLIENT_PID" ]]; then kill "$CLIENT_PID" 2>/dev/null || true; fi
    stop_sender
    if [[ -n "$PLAIN" && -n "$RICH" ]]; then
        osascript Tests/host/CloseTextEditFixtures.applescript "$PLAIN" "$RICH" >/dev/null 2>&1 || true
    fi
    if [[ "$OVERRIDE_SET" == 1 ]]; then
        defaults delete "$IME_DOMAIN" correctionModeTestOverride 2>/dev/null || true
        "$OUT/TextEditNativeKey" --correction-settings-changed 2>/dev/null || true
    fi
    "$WORKER" --keyhue-select-input-source "$ORIGINAL" || true
    if [[ "$UTILITY_RUNNING" == 1 ]]; then open "$UTILITY_APP_PATH"; fi
    # Restoring the original source can start and activate the service. Keep
    # that apart from the tested window so it is never read as a test callback.
    local log_name=input-method-server.log
    if [[ "$TEST_LOG_SAVED" == 1 ]]; then log_name=input-method-cleanup.log; fi
    KEYHUE_LOG_FILE="$IMK_LOG_FILE" keyhue_log_save "$OUT" "$IMK_LOG_MARK"
    if [[ -f "$OUT/keyhue-file.log" ]]; then mv "$OUT/keyhue-file.log" "$OUT/$log_name"; fi
}
save_test_log() {
    KEYHUE_LOG_FILE="$IMK_LOG_FILE" keyhue_log_save "$OUT" "$IMK_LOG_MARK"
    if [[ -f "$OUT/keyhue-file.log" ]]; then mv "$OUT/keyhue-file.log" "$OUT/input-method-server.log"; fi
    IMK_LOG_MARK="$(KEYHUE_LOG_FILE="$IMK_LOG_FILE" keyhue_log_mark)"
    TEST_LOG_SAVED=1
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
FRESH_CLIENT="${KEYHUE_TEST_TEXTEDIT_FRESH_CLIENT:-0}"
if [[ "$FRESH_CLIENT" == 1 ]]; then
    [[ "${KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY:-0}" == 1 && "${KEYHUE_TEST_TEXTEDIT_COLD_START:-0}" == 1 ]] || { echo "Fresh client requires entry-only cold start" >&2; exit 64; }
    # Never quit the user's editor; only a launch from this runner is fresh.
    if pgrep -x TextEdit >/dev/null; then echo "Quit TextEdit before the fresh-client test" >&2; exit 64; fi
    # Launch the editor with a keyboard layout so it opens no session to the service.
    "$WORKER" --keyhue-select-input-source com.apple.keylayout.ABC
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
    WATCHDOG_MINUTES=3
fi
if [[ "${KEYHUE_TEST_TEXTEDIT_WINDOWS_ONLY:-0}" == 1 ]]; then
    PROBE_ARGUMENTS=(--windows-only)
    ACCEPTANCE='PASS: TextEdit window input acceptance'
    WATCHDOG_MINUTES=2
fi
if [[ "${KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY:-0}" == 1 ]]; then
    [[ "${KEYHUE_TEST_TEXTEDIT_WINDOWS_ONLY:-0}" != 1 ]] || { echo "Choose entry-only or windows-only" >&2; exit 64; }
    PROBE_ARGUMENTS=(--entry-only)
    ACCEPTANCE='PASS: TextEdit entry input acceptance'
    WATCHDOG_MINUTES=3
fi
# ADR 0064: TextEdit is a verified correction app. The test never reads or changes
# the user's correction setting: a short-lived override in the input method's own
# preferences selects the mode (off for every other test), removed on exit.
CORRECTION="${KEYHUE_TEST_TEXTEDIT_CORRECTION:-off}"
case "$CORRECTION" in
    off) ;;
    manual|automatic)
        [[ "${KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY:-0}" != 1 && "${KEYHUE_TEST_TEXTEDIT_WINDOWS_ONLY:-0}" != 1 ]] || { echo "Choose one TextEdit test scope" >&2; exit 64; }
        if defaults read io.github.sejoung.keyhue correctionExcludedApps 2>/dev/null | grep -Fq '"com.apple.TextEdit"'; then
            echo "TextEdit is in your Apps That Are Never Changed list; the correction test cannot run." >&2; exit 64
        fi
        # ADR 0068: the cases press the default shortcut (⌥↩); the user's choice is never changed.
        if defaults read io.github.sejoung.keyhue correctionShortcut >/dev/null 2>&1; then
            echo "Your correction shortcut is not the default ⌥↩; the correction test cannot run." >&2; exit 64
        fi
        PROBE_ARGUMENTS=("--correction-$CORRECTION")
        ACCEPTANCE="PASS: TextEdit correction acceptance mode=$CORRECTION"
        WATCHDOG_MINUTES=3 ;;
    *) echo "Invalid TextEdit correction mode" >&2; exit 64 ;;
esac
defaults write "$IME_DOMAIN" correctionModeTestOverride "$CORRECTION@$(( $(date +%s) + 900 ))"
OVERRIDE_SET=1
"$OUT/TextEditNativeKey" --correction-settings-changed
case "${KEYHUE_TEST_TEXTEDIT_MODE_SWITCH:-menu}" in
    menu) PROBE_ARGUMENTS+=(--menu-switch) ;;
    worker) PROBE_ARGUMENTS+=(--worker-switch) ;;
    shortcut)
        [[ "${KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY:-0}" == 1 ]] || { echo "Shortcut switching requires entry-only scope" >&2; exit 64; }
        PROBE_ARGUMENTS+=(--shortcut-switch) ;;
    repair)
        [[ "${KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY:-0}" == 1 ]] || { echo "Session repair switching requires entry-only scope" >&2; exit 64; }
        PROBE_ARGUMENTS+=(--repair-switch) ;;
    app)
        [[ "${KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY:-0}" == 1 ]] || { echo "Live app switching requires entry-only scope" >&2; exit 64; }
        SENDER_APP="$OUT/TextEditNativeKey.app"
        mkdir -p "$SENDER_APP/Contents/MacOS"
        xcrun swiftc -swift-version 6 Tests/host/TextEditSourceSender.swift -o "$SENDER_APP/Contents/MacOS/TextEditSourceSender" > "$OUT/source-sender-build.log" 2>&1
        cat > "$SENDER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.sejoung.keyhue.testclient.source-sender</string>
<key>CFBundleExecutable</key><string>TextEditSourceSender</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
        codesign --force --sign - "$SENDER_APP" > "$OUT/source-sender-signing.log" 2>&1
        PROBE_ARGUMENTS+=(--app-switch) ;;
    *) echo "Invalid TextEdit mode switch method" >&2; exit 64 ;;
esac
case "${KEYHUE_TEST_TEXTEDIT_EXIT_SOURCE:-latin}" in
    latin) PROBE_ARGUMENTS+=(--exit-latin) ;;
    abc) PROBE_ARGUMENTS+=(--exit-abc) ;;
    *) echo "Invalid TextEdit exit source" >&2; exit 64 ;;
esac
case "${KEYHUE_TEST_TEXTEDIT_PREPARE_MODE:-menu}" in
    menu) PROBE_ARGUMENTS+=(--prepare-menu) ;;
    worker) PROBE_ARGUMENTS+=(--prepare-worker) ;;
    *) echo "Invalid TextEdit preparation method" >&2; exit 64 ;;
esac
if [[ "${KEYHUE_TEST_TEXTEDIT_COLD_START:-0}" == 1 ]]; then
    [[ "${KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY:-0}" == 1 ]] || { echo "Cold start requires entry-only scope" >&2; exit 64; }
    PROBE_ARGUMENTS+=(--cold-start)
    if [[ "$FRESH_CLIENT" == 1 ]]; then PROBE_ARGUMENTS+=(--fresh-client); fi
fi
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
save_test_log
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=""
stop_sender
if [[ -f "$OUT/client.log" ]]; then cat "$OUT/client.log"; fi
"$WORKER" --keyhue-select-input-source "$ORIGINAL"
"$WORKER" --keyhue-input-source-status > "$OUT/after.json"
python3 -c 'import json,sys; before=json.load(open(sys.argv[1])); after=json.load(open(sys.argv[2])); assert before["currentID"] == after["currentID"], "original input source not restored"; assert sorted(before.get("configuredIDs") or []) == sorted(after.get("configuredIDs") or []), "configured input sources changed"' "$OUT/before.json" "$OUT/after.json"
[[ "$CLIENT_STATUS" == 0 ]] || { cat "$OUT/client-stderr.log" >&2; exit "$CLIENT_STATUS"; }
grep -Fqx "$ACCEPTANCE" "$OUT/client.log"
echo "==> results: $OUT"
