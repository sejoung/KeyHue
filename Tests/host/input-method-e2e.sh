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
restore() { "$WORKER" --keyhue-select-input-source "$ORIGINAL" || true; }
trap restore EXIT
APP="$OUT/InputMethodClient.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 6 Tests/host/InputMethodClient.swift -o "$APP/Contents/MacOS/InputMethodClient" > "$OUT/build.log" 2>&1
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.sejoung.keyhue.testclient</string>
<key>CFBundleExecutable</key><string>InputMethodClient</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" > "$OUT/signing.log" 2>&1
open -W -n "$APP" --args "$OUT/client.log"
cat "$OUT/client.log"
"$WORKER" --keyhue-select-input-source "$ORIGINAL"
"$WORKER" --keyhue-input-source-status > "$OUT/after.json"
python3 -c 'import json,sys; before=json.load(open(sys.argv[1])); after=json.load(open(sys.argv[2])); assert before["currentID"] == after["currentID"], "original input source not restored"' "$OUT/before.json" "$OUT/after.json"
rg -q '^PASS: actual IMK client acceptance$' "$OUT/client.log"
echo "==> results: $OUT"
