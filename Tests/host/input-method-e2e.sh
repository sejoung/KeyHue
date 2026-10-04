#!/usr/bin/env bash
# Opt-in Cocoa/IMK/UI acceptance. Requires already installed modes, temporarily
# focuses an isolated test window, and always restores the original input source.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
[[ "${KEYHUE_TEST_HOST_E2E:-0}" == 1 ]] || { echo "Set KEYHUE_TEST_HOST_E2E=1 to opt into the temporary test window." >&2; exit 64; }
: "${KEYHUE_TEST_APP_PATH:?absolute packaged KeyHue.app path required}"
WORKER="$KEYHUE_TEST_APP_PATH/Contents/MacOS/KeyHue"
[[ -x "$WORKER" && "$KEYHUE_TEST_APP_PATH" == /* ]] || { echo "Invalid packaged app path" >&2; exit 64; }
# shellcheck source=scripts/artifacts.sh
source scripts/artifacts.sh
OUT="$(artifacts_dir input-method-e2e)"
"$WORKER" --keyhue-input-source-status > "$OUT/before.json"
ORIGINAL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["currentID"] or "")' "$OUT/before.json")"
[[ -n "$ORIGINAL" ]] || { echo "Cannot read original source" >&2; exit 1; }
UTILITY_RUNNING=0
UTILITY_APP_PATH="$KEYHUE_TEST_APP_PATH"
if pgrep -x KeyHue >/dev/null; then
    UTILITY_RUNNING=1
    UTILITY_APP_PATH="$(osascript -e 'POSIX path of (path to application id "io.github.sejoung.keyhue")')"
fi
restore() {
    "$WORKER" --keyhue-select-input-source "$ORIGINAL" || true
    if [[ "$UTILITY_RUNNING" == 1 ]]; then open "$UTILITY_APP_PATH"; fi
}
trap restore EXIT
# Pair routing would immediately redirect the ABC control case. Stop only the
# utility, keep the IMK service, and reopen the utility on every exit path.
if [[ "$UTILITY_RUNNING" == 1 ]]; then
    osascript -e 'tell application id "io.github.sejoung.keyhue" to quit'
    for _ in {1..50}; do
        if ! pgrep -x KeyHue >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x KeyHue >/dev/null; then echo "KeyHue did not quit; refusing to run with routing active" >&2; exit 1; fi
fi
if [[ "${KEYHUE_TEST_UPDATE_SERVICE:-0}" == 1 ]]; then
    "$WORKER" --keyhue-select-input-source com.apple.keylayout.ABC
    KEYHUE_TEST_HOST_UPDATE=1 swift test --filter updateInstalledServiceThenRepeatedInstallIsANoop > "$OUT/update.log" 2>&1
fi
PROBE_ARGUMENTS=()
CLIENT_ID=io.github.sejoung.keyhue.testclient
if [[ "${KEYHUE_TEST_CORRECTION_PROBE:-0}" == 1 ]]; then
    PACKAGED_SERVICE="$KEYHUE_TEST_APP_PATH/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
    INSTALLED_SERVICE="$HOME/Library/Input Methods/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
    if ! cmp -s "$PACKAGED_SERVICE" "$INSTALLED_SERVICE"; then
        echo "Update the installed service from this packaged app before running the correction probe." >&2
        exit 1
    fi
    CLIENT_ID=io.github.sejoung.keyhue.testclient.correction-probe
    PROBE_ARGUMENTS=(--correction-probe)
fi
MANUAL_PROBE=0
if [[ "${KEYHUE_TEST_MANUAL_PROBE:-0}" == 1 ]]; then
    # ADR 0064 step 1 experiment: the runner performs switches the client cannot.
    [[ "${KEYHUE_TEST_CORRECTION_PROBE:-0}" != 1 ]] || { echo "Choose one probe" >&2; exit 64; }
    PACKAGED_SERVICE="$KEYHUE_TEST_APP_PATH/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
    INSTALLED_SERVICE="$HOME/Library/Input Methods/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
    if ! cmp -s "$PACKAGED_SERVICE" "$INSTALLED_SERVICE"; then
        echo "Update the installed service from this packaged app before running the manual probe." >&2
        exit 1
    fi
    MANUAL_PROBE=1
    CLIENT_ID=io.github.sejoung.keyhue.testclient.manual-probe
    PROBE_ARGUMENTS=(--manual-probe)
    xcrun swiftc -swift-version 6 Tests/host/ManualSignalSwitch.swift -o "$OUT/ManualSignalSwitch" > "$OUT/helper-build.log" 2>&1
fi
HANGUL_ID=io.github.sejoung.keyhue.inputmethod.spike.Hangul
perform_request() {
    case "$1" in
        worker) "$WORKER" --keyhue-select-input-source "$HANGUL_ID" ;;
        shortcut) "$OUT/ManualSignalSwitch" --shortcut ;;
        menu)
            local name
            name="$("$OUT/ManualSignalSwitch" --source-name "$HANGUL_ID")" || return 1
            osascript - "$name" <<'APPLESCRIPT'
on run argv
    set sourceName to item 1 of argv
    tell application "System Events" to tell process "TextInputMenuAgent"
        click menu bar item 1 of menu bar 2
        delay 0.1
        try
            if exists menu item sourceName of menu 1 of menu bar item 1 of menu bar 2 then
                click menu item sourceName of menu 1 of menu bar item 1 of menu bar 2
            else
                click menu item "KeyHue 실험 – 두벌식" of menu 1 of menu bar item 1 of menu bar 2
            end if
        on error message number errorNumber
            key code 53
            error message number errorNumber
        end try
    end tell
end run
APPLESCRIPT
            ;;
        *) return 1 ;;
    esac
}
sw_vers > "$OUT/environment.log"
plutil -p "$HOME/Library/Input Methods/KeyHueInputMethodSpike.app/Contents/Info.plist" >> "$OUT/environment.log"
APP="$OUT/InputMethodClient.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 6 Tests/host/InputMethodClient.swift -o "$APP/Contents/MacOS/InputMethodClient" > "$OUT/build.log" 2>&1
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$CLIENT_ID</string>
<key>CFBundleExecutable</key><string>InputMethodClient</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" > "$OUT/signing.log" 2>&1
CLIENT_STATUS=0
LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
if [[ "$MANUAL_PROBE" == 1 ]]; then
    open -W -n --stderr "$OUT/client-stderr.log" --stdout "$OUT/client-stdout.log" "$APP" --args "$OUT/client.log" "${PROBE_ARGUMENTS[@]}" &
    CLIENT_PID=$!
    while kill -0 "$CLIENT_PID" 2>/dev/null; do
        for request in "$OUT"/request-*; do
            # The client writes atomically; skip its temporary file.
            ordinal="${request##*/request-}"
            [[ "$ordinal" =~ ^[0-9]+$ && -f "$request" ]] || continue
            action="$(cat "$request")" || continue
            rm -f "$request"
            if result="$(perform_request "$action" 2>&1)"; then echo ok > "$OUT/done-$ordinal"
            else echo "failed: $result" > "$OUT/done-$ordinal"; fi
        done
        sleep 0.02
    done
    wait "$CLIENT_PID" || CLIENT_STATUS=$?
    # Diagnostic callback names, lengths and outcomes only (no text or keys).
    /usr/bin/log show --start "$LOG_START" --style compact \
        --predicate 'subsystem == "io.github.sejoung.keyhue.inputmethod.spike" AND (eventMessage CONTAINS "manual correction" OR eventMessage CONTAINS "correction detector")' > "$OUT/manual-probe-server.log" 2>&1 || true
else
    open -W -n --stderr "$OUT/client-stderr.log" --stdout "$OUT/client-stdout.log" "$APP" --args "$OUT/client.log" "${PROBE_ARGUMENTS[@]+"${PROBE_ARGUMENTS[@]}"}" || CLIENT_STATUS=$?
fi
if [[ -f "$OUT/client.log" ]]; then cat "$OUT/client.log"; fi
"$WORKER" --keyhue-select-input-source "$ORIGINAL"
"$WORKER" --keyhue-input-source-status > "$OUT/after.json"
python3 -c 'import json,sys; before=json.load(open(sys.argv[1])); after=json.load(open(sys.argv[2])); assert before["currentID"] == after["currentID"], "original input source not restored"; assert sorted(before.get("configuredIDs") or []) == sorted(after.get("configuredIDs") or []), "configured input sources changed"' "$OUT/before.json" "$OUT/after.json"
[[ "$CLIENT_STATUS" == 0 ]] || exit "$CLIENT_STATUS"
grep -q '^PASS: actual IMK client acceptance$' "$OUT/client.log"
if [[ "$MANUAL_PROBE" == 1 ]]; then grep -q '^PASS: manual signal experiment recorded$' "$OUT/client.log"; fi
echo "==> results: $OUT"
