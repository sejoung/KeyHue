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
require_matching_service() {
    local packaged="$KEYHUE_TEST_APP_PATH/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
    local installed="$HOME/Library/Input Methods/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
    cmp -s "$packaged" "$installed" || {
        echo "Update the installed service from this packaged app first (KEYHUE_TEST_UPDATE_SERVICE=1)." >&2
        return 1
    }
}
# Acceptance must exercise this build, including the basic composition cases.
# Reject a stale service before changing focus or stopping the utility.
if [[ "${KEYHUE_TEST_UPDATE_SERVICE:-0}" != 1 ]]; then require_matching_service; fi
# shellcheck source=scripts/artifacts.sh
source scripts/artifacts.sh
OUT="$(artifacts_dir input-method-e2e)"
IMK_LOG_FILE="$HOME/Library/Logs/KeyHue/KeyHueInputMethod.log"
IMK_LOG_MARK="$(KEYHUE_LOG_FILE="$IMK_LOG_FILE" keyhue_log_mark)"
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
    KEYHUE_LOG_FILE="$IMK_LOG_FILE" keyhue_log_save "$OUT" "$IMK_LOG_MARK" || true
    if [[ -f "$OUT/keyhue-file.log" ]]; then mv "$OUT/keyhue-file.log" "$OUT/input-method-server.log" || true; fi
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
require_matching_service
PROBE_ARGUMENTS=()
CLIENT_ID=io.github.sejoung.keyhue.testclient
if [[ "${KEYHUE_TEST_CORRECTION_PROBE:-0}" == 1 ]]; then
    CLIENT_ID=io.github.sejoung.keyhue.testclient.correction-probe
    PROBE_ARGUMENTS=(--correction-probe)
fi
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
open -W -n --stderr "$OUT/client-stderr.log" --stdout "$OUT/client-stdout.log" "$APP" --args "$OUT/client.log" "${PROBE_ARGUMENTS[@]+"${PROBE_ARGUMENTS[@]}"}" || CLIENT_STATUS=$?
if [[ -f "$OUT/client.log" ]]; then cat "$OUT/client.log"; fi
"$WORKER" --keyhue-select-input-source "$ORIGINAL"
"$WORKER" --keyhue-input-source-status > "$OUT/after.json"
python3 -c 'import json,sys; before=json.load(open(sys.argv[1])); after=json.load(open(sys.argv[2])); assert before["currentID"] == after["currentID"], "original input source not restored"; assert sorted(before.get("configuredIDs") or []) == sorted(after.get("configuredIDs") or []), "configured input sources changed"' "$OUT/before.json" "$OUT/after.json"
[[ "$CLIENT_STATUS" == 0 ]] || exit "$CLIENT_STATUS"
grep -q '^PASS: actual IMK client acceptance$' "$OUT/client.log"
echo "==> results: $OUT"
