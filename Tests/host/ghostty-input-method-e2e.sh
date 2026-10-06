#!/usr/bin/env bash
# Opt-in Ghostty test (ADR 0066). Opens its own Ghostty process whose only program
# records the bytes Ghostty sends, types into it with real keys and restores sources.
# The user's Ghostty windows are never read or typed into.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
[[ "${KEYHUE_TEST_GHOSTTY:-0}" == 1 ]] || { echo "Set KEYHUE_TEST_GHOSTTY=1 to open a Ghostty test window." >&2; exit 64; }
: "${KEYHUE_TEST_APP_PATH:?absolute packaged KeyHue.app path required}"
WORKER="$KEYHUE_TEST_APP_PATH/Contents/MacOS/KeyHue"
[[ -x "$WORKER" && "$KEYHUE_TEST_APP_PATH" == /* ]] || { echo "Invalid packaged app path" >&2; exit 64; }
GHOSTTY_APP="${KEYHUE_TEST_GHOSTTY_APP:-/Applications/Ghostty.app}"
# ADR 0067·0068: terminal word fixing posts Backspace keys and needs the input
# method's own Accessibility access, which only the user can grant. Opt-in.
CORRECTION="${KEYHUE_TEST_GHOSTTY_CORRECTION:-0}"
if [[ "$CORRECTION" == 1 ]] && defaults read io.github.sejoung.keyhue correctionExcludedApps 2>/dev/null | grep -Fq '"com.mitchellh.ghostty"'; then
    echo "Ghostty is in your Apps That Are Never Changed list; the correction test cannot run." >&2; exit 64
fi
if [[ "$CORRECTION" == 1 ]] && defaults read io.github.sejoung.keyhue correctionShortcut >/dev/null 2>&1; then
    echo "Your correction shortcut is not the default ⌥↩; the correction test cannot run." >&2; exit 64
fi
# ADR 0071: the user's "previous input source" shortcut with the utility running,
# from source histories no menu prepares (ABC left as the previous source by an
# earlier setup). Routing and session repair live in the utility, so this mode
# runs the packaged app instead of quitting KeyHue, and runs only these checks.
TOGGLE="${KEYHUE_TEST_GHOSTTY_TOGGLE:-0}"
PREVIOUS_SOURCE_KEY=""
if [[ "$TOGGLE" == 1 ]]; then
    for key in integrateInputMethod routeInputMethodPair; do
        [[ "$(defaults read io.github.sejoung.keyhue "$key" 2>/dev/null)" == 1 ]] || {
            echo "Turn on the input method and its ABC routing in KeyHue first ($key)." >&2; exit 64; }
    done
    # "<key code>@<modifier flags>" of system hot key 60, only an enabled standard shortcut.
    PREVIOUS_SOURCE_KEY="$(plutil -extract AppleSymbolicHotKeys.60 json -o - "$HOME/Library/Preferences/com.apple.symbolichotkeys.plist" 2>/dev/null \
        | python3 -c '
import json, sys
entry = json.load(sys.stdin)
value = entry.get("value", {})
parameters = value.get("parameters", [])
if entry.get("enabled") and value.get("type") == "standard" and len(parameters) == 3 and parameters[2] > 0:
    print(f"{parameters[1]}@{parameters[2]}")' 2>/dev/null || true)"
    [[ -n "$PREVIOUS_SOURCE_KEY" ]] || { echo "Turn on Keyboard Shortcuts → Input Sources → Select the previous input source first." >&2; exit 64; }
fi
[[ -x "$GHOSTTY_APP/Contents/MacOS/ghostty" ]] || { echo "Ghostty not found: $GHOSTTY_APP" >&2; exit 64; }
PACKAGED_SERVICE="$KEYHUE_TEST_APP_PATH/Contents/Helpers/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
INSTALLED_SERVICE="$HOME/Library/Input Methods/KeyHueInputMethodSpike.app/Contents/MacOS/KeyHueInputMethodSpike"
cmp -s "$PACKAGED_SERVICE" "$INSTALLED_SERVICE" || { echo "Update the installed service from this packaged app first." >&2; exit 1; }
# shellcheck source=scripts/artifacts.sh
source scripts/artifacts.sh
OUT="$(artifacts_dir input-method-ghostty)"
# The test window's command is one space-separated argument (see `open` below).
[[ "$ROOT$OUT" != *" "* ]] || { echo "The Ghostty test needs a checkout path without spaces." >&2; exit 64; }
IMK_LOG_FILE="$HOME/Library/Logs/KeyHue/KeyHueInputMethod.log"
IMK_LOG_MARK="$(KEYHUE_LOG_FILE="$IMK_LOG_FILE" keyhue_log_mark)"
"$WORKER" --keyhue-input-source-status > "$OUT/before.json"
ORIGINAL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["currentID"] or "")' "$OUT/before.json")"
[[ -n "$ORIGINAL" ]] || { echo "Cannot read original source" >&2; exit 1; }
HANGUL=io.github.sejoung.keyhue.inputmethod.spike.Hangul
LATIN=io.github.sejoung.keyhue.inputmethod.spike.Latin
IME_DOMAIN=io.github.sejoung.keyhue.inputmethod.spike
UTILITY_RUNNING=0
UTILITY_APP_PATH="$KEYHUE_TEST_APP_PATH"
UTILITY_LOG_FILE="$HOME/Library/Logs/KeyHue/KeyHue.log"
UTILITY_LOG_MARK=""
GHOSTTY_PID=""
FAILED=0
if pgrep -x KeyHue >/dev/null; then
    UTILITY_RUNNING=1
    UTILITY_APP_PATH="$(osascript -e 'POSIX path of (path to application id "io.github.sejoung.keyhue")')"
fi
stop_ghostty() {
    # Only the process this runner started: its command line names this run's files.
    if [[ -n "$GHOSTTY_PID" ]] && ps -p "$GHOSTTY_PID" -o command= | grep -Fq "$OUT/"; then
        kill "$GHOSTTY_PID" 2>/dev/null || true
        for _ in {1..20}; do
            if ! kill -0 "$GHOSTTY_PID" 2>/dev/null; then break; fi
            sleep 0.05
        done
    fi
    GHOSTTY_PID=""
}
quit_utility() {
    osascript -e 'tell application id "io.github.sejoung.keyhue" to quit'
    for _ in {1..50}; do
        if ! pgrep -x KeyHue >/dev/null; then return 0; fi
        sleep 0.1
    done
    return 1
}
restore() {
    stop_ghostty
    if [[ "$TOGGLE" == 1 && -n "$UTILITY_LOG_MARK" ]]; then
        tail -c "+$(( UTILITY_LOG_MARK + 1 ))" "$UTILITY_LOG_FILE" > "$OUT/keyhue-utility.log" 2>/dev/null || true
        quit_utility || true
    fi
    defaults delete "$IME_DOMAIN" correctionModeTestOverride 2>/dev/null || true
    "$WORKER" --keyhue-select-input-source "$ORIGINAL" || true
    if [[ "$UTILITY_RUNNING" == 1 ]]; then open "$UTILITY_APP_PATH"; fi
    KEYHUE_LOG_FILE="$IMK_LOG_FILE" keyhue_log_save "$OUT" "$IMK_LOG_MARK"
    if [[ -f "$OUT/keyhue-file.log" ]]; then mv "$OUT/keyhue-file.log" "$OUT/input-method-server.log"; fi
}
trap restore EXIT
if [[ "$UTILITY_RUNNING" == 1 ]]; then
    quit_utility || { echo "KeyHue did not quit" >&2; exit 1; }
fi
if [[ "$TOGGLE" == 1 ]]; then
    # The packaged app under test, started before the test window so it is not in front.
    UTILITY_LOG_MARK="$(KEYHUE_LOG_FILE="$UTILITY_LOG_FILE" keyhue_log_mark)"
    open -n "$KEYHUE_TEST_APP_PATH"
    for _ in {1..50}; do
        if pgrep -x KeyHue >/dev/null; then break; fi
        sleep 0.1
    done
    pgrep -x KeyHue >/dev/null || { echo "KeyHue did not start" >&2; exit 1; }
    sleep 2
fi
# Word correction is off except in its own cases (ADR 0064 test override, removed on exit).
set_correction() {
    defaults write "$IME_DOMAIN" correctionModeTestOverride "$1@$(( $(date +%s) + 900 ))"
    "$OUT/GhosttyKeys" --correction-settings-changed
    sleep 0.3
}
sw_vers > "$OUT/environment.log"
plutil -p "$GHOSTTY_APP/Contents/Info.plist" | grep -E 'CFBundle(ShortVersionString|Version)' >> "$OUT/environment.log"
xcrun swiftc -swift-version 6 Tests/host/GhosttyKeys.swift -o "$OUT/GhosttyKeys" > "$OUT/build.log" 2>&1
set_correction off

report() { echo "$1" | tee -a "$OUT/client.log"; }
# Empty while the screen is locked.
front_pid() { osascript -e 'tell application "System Events" to get unix id of first application process whose frontmost is true' 2>/dev/null || true; }

choose_mode() {
    local name fallback
    name="$("$OUT/GhosttyKeys" --source-name "$1")"
    fallback="$name"
    if [[ "$1" == "$HANGUL" ]]; then fallback="KeyHue 실험 – 두벌식"; fi
    if [[ "$1" == "$LATIN" ]]; then fallback="KeyHue 실험 – 영문"; fi
    [[ "$(front_pid)" == "$GHOSTTY_PID" ]] || { report "FAIL: test lost the Ghostty test window"; exit 1; }
    # The real input menu, as a user switches in the focused window.
    osascript - "$name" "$fallback" > /dev/null <<'APPLESCRIPT'
on run argv
    tell application "System Events" to tell process "TextInputMenuAgent"
        click menu bar item 1 of menu bar 2
        delay 0.1
        try
            if exists menu item (item 1 of argv) of menu 1 of menu bar item 1 of menu bar 2 then
                click menu item (item 1 of argv) of menu 1 of menu bar item 1 of menu bar 2
            else
                click menu item (item 2 of argv) of menu 1 of menu bar item 1 of menu bar 2
            end if
        on error message number errorNumber
            key code 53
            error message number errorNumber
        end try
    end tell
end run
APPLESCRIPT
    local current=""
    for _ in {1..20}; do
        sleep 0.1
        current="$("$WORKER" --keyhue-input-source-status | python3 -c 'import json,sys; print(json.load(sys.stdin)["currentID"])')"
        if [[ "$current" == "$1" ]]; then break; fi
    done
    [[ "$current" == "$1" ]] || { report "FAIL: input menu did not select $1 (current $current)"; exit 1; }
}

# Sends keys and prints what Ghostty sent for them, bracketed paste removed.
type_keys() {
    local before
    before="$(stat -f %z "$BYTES")"
    "$OUT/GhosttyKeys" "$GHOSTTY_PID" "$@" || { report "FAIL: test lost the Ghostty test window"; exit 1; }
    sleep 0.5
    python3 - "$BYTES" "$before" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()[int(sys.argv[2]):]
print(repr(data.replace(b"\x1b[200~", b"").replace(b"\x1b[201~", b"").decode("utf-8", "replace")))
PY
}

check() {
    local label="$1" expected="$2" actual
    shift 2
    actual="$(type_keys "$@")"
    if [[ "$actual" == "$expected" ]]; then
        report "PASS: $label"
    else
        report "FAIL: $label: expected $expected got $actual"
        FAILED=1
    fi
}

# Ghostty can move focus between its own clients for a moment after launch; checks
# start once the logger's window records a key (Space, nothing composing).
wait_for_logger() {
    for _ in {1..5}; do
        if [[ "$(type_keys 49)" == "' '" ]]; then return; fi
    done
    report "FAIL: Ghostty test window did not record keys"
    exit 1
}

# What Ghostty sent since `mark`, bracketed paste removed.
mark() { MARK="$(stat -f %z "$BYTES")"; }
since() {
    python3 -c '
import sys
data = open(sys.argv[1], "rb").read()[int(sys.argv[2]):]
print(repr(data.replace(b"\x1b[200~", b"").replace(b"\x1b[201~", b"").decode("utf-8", "replace")))
' "$BYTES" "$MARK"
}
expect_since() {
    local label="$1" expected="$2" actual
    sleep 0.8
    actual="$(since)"
    if [[ "$actual" == "$expected" ]]; then
        report "PASS: $label"
    else
        report "FAIL: $label: expected $expected got $actual"
        FAILED=1
    fi
}
send() { "$OUT/GhosttyKeys" "$GHOSTTY_PID" "$@" || { report "FAIL: test lost the Ghostty test window"; exit 1; }; }
deletes() { python3 -c 'import sys; print("\\x7f" * int(sys.argv[1]), end="")' "$1"; }

FIX="36@524288" # ADR 0068: the default correction shortcut, ⌥↩

# ADR 0067·0068: the shortcut erases the word with Backspace (0x7f) and inserts the
# fix; pressing it again right away restores the word exactly.
check_terminal_correction() {
    # fixedLength: characters, not bytes (the shell's locale may count bytes).
    local protocol="$1" keys="$2" typed="$3" fixed="$4" fixedLength="$5"
    set_correction manual
    choose_mode "$LATIN"
    # shellcheck disable=SC2086
    # The separator is sent before measuring: right after choosing the mode that is
    # already selected, the input menu can take the first key.
    send 49; mark; send $keys 49; send "$FIX"
    expect_since "$protocol: Latin-mode word fixed with the shortcut" "'$typed $(deletes $(( ${#typed} + 1 )))$fixed '"
    mark; send "$FIX"
    expect_since "$protocol: the shortcut again restores the word" "'$(deletes $(( fixedLength + 1 )))$typed '"
    choose_mode "$HANGUL"
    mark; send 49 40 14 16 11 31 0 15 2 "$FIX" # keyboard → ㅏ됴ㅠㅐㅁㄱㅇ
    expect_since "$protocol: Korean-mode word fixed with the shortcut" "' ㅏ됴ㅠㅐㅁㄱㅇ$(deletes 7)keyboard'"
    choose_mode "$HANGUL"
    mark; send 49 0 1 2 "$FIX" # asd → ㅁㄴㅇ: each jamo is committed by the next key
    expect_since "$protocol: single jamo fixed with the shortcut" "' ㅁㄴㅇ$(deletes 3)asd'"
    # Nothing composing: the shortcut must not reach the shell, whose extra
    # character would leave the first jamo behind (ㅁasd).
    choose_mode "$HANGUL"
    mark; send 49 0 1 2 49 "$FIX"
    expect_since "$protocol: a word finished with Space is fixed and the shortcut stays out of the shell" "' ㅁㄴㅇ $(deletes 4)asd '"
    # ↩ tapped twice with ⌥ held: one request, fixed once ⌥ is released.
    choose_mode "$HANGUL"
    mark; send 49 0 1 2 "36@524288x2"
    expect_since "$protocol: pressing again with the modifier held fixes once" "' ㅁㄴㅇ$(deletes 3)asd'"
    # Digits and symbols are part of the word and stay as they are. The fix left
    # this mode selected, and choosing it again lets the input menu take the next
    # key: two separators, so the word always starts after one.
    choose_mode "$LATIN"
    send 49 49; mark; send 2 40 1 1 32 2 "18@131072" "$FIX" # dkssud! → 안녕!
    expect_since "$protocol: a word with a symbol is fixed whole" "'dkssud!$(deletes 7)안녕!'"
    choose_mode "$HANGUL"
    send 49 49; mark; send 15 40 19 "$FIX" # 가2 → rk2: the digit ends the composition
    expect_since "$protocol: a digit after a composition is part of the word" "'가2$(deletes 2)rk2'"
    # A password prompt holds secure input: nothing is fixed and the keys typed
    # there are not remembered, so the shortcut reaches the program as usual. The
    # word ends with Space first: Ghostty drops a Return-like key that commits a
    # composition (see the Return probe above).
    local altReturn='\x1b\r'
    [[ "$protocol" == kitty ]] && altReturn='\x1b[13;3u'
    choose_mode "$LATIN"
    send 49 49
    "$OUT/GhosttyKeys" --secure-input 4 & local secure=$!
    sleep 0.3
    mark; send 2 40 1 1 32 2 49 "$FIX"
    wait "$secure"
    expect_since "$protocol: nothing is fixed while secure input is on" "'dkssud $altReturn'"
    # shellcheck disable=SC2086
    mark; send 49 $keys 49; choose_mode "$HANGUL"
    expect_since "$protocol: switching modes does not fix the word" "' $typed '"
    set_correction off
}

probe() {
    local label="$1" actual
    shift
    actual="$(type_keys "$@")"
    report "PROBE: $label sent $actual"
}

# Opens this run's Ghostty window for `$protocol` and waits until it is in front.
start_window() {
    local protocol="$1"
    BYTES="$OUT/ghostty-$protocol.bin"
    : > "$BYTES"
    # One argument that is not a file path: AppKit opens launch arguments that
    # are existing files, and Ghostty asks "Allow Ghostty to execute …?" for each.
    open -na "$GHOSTTY_APP" --args "--initial-command=direct:/usr/bin/python3 $ROOT/Tests/host/GhosttyByteLogger.py $BYTES $protocol"
    for _ in {1..50}; do
        GHOSTTY_PID="$(pgrep -f "GhosttyByteLogger.py $BYTES" | while read -r pid; do
            if [[ "$(ps -p "$pid" -o comm=)" == "$GHOSTTY_APP/Contents/MacOS/ghostty" ]]; then echo "$pid"; fi
        done | head -1)"
        if [[ -n "$GHOSTTY_PID" ]]; then break; fi
        sleep 0.1
    done
    [[ -n "$GHOSTTY_PID" ]] || { report "FAIL: Ghostty test window did not start"; exit 1; }
    for _ in {1..50}; do
        if [[ "$(front_pid)" == "$GHOSTTY_PID" ]]; then break; fi
        sleep 0.1
    done
    [[ "$(front_pid)" == "$GHOSTTY_PID" ]] || { report "FAIL: Ghostty test window is not in front (screen locked?)"; exit 1; }
    sleep 1
    report "PROBE: protocol=$protocol pid=$GHOSTTY_PID"
}

# ADR 0071: the previous-source shortcut, then the first word right away. Checks
# the source, what the window received, and what the utility saw in between: an
# ABC selection means ⌘Space went back through ABC and the external route.
utility_log_mark() { KEYHUE_LOG_FILE="$UTILITY_LOG_FILE" keyhue_log_mark; }
current_source() { "$WORKER" --keyhue-input-source-status | python3 -c 'import json,sys; print(json.load(sys.stdin)["currentID"])'; }
toggle_and_type() {
    local label="$1" expected="$2" routed="$3" since_mark seen abc routes repairs current bytes want="'dk '"
    [[ "$expected" == "$HANGUL" ]] && want="'아 '"
    since_mark="$(utility_log_mark)"
    send "$PREVIOUS_SOURCE_KEY"
    mark; send 2 40 49 # dk + Space: 아 in Korean
    sleep 0.8
    bytes="$(since)"
    current="$(current_source)"
    seen="$(tail -c "+$(( since_mark + 1 ))" "$UTILITY_LOG_FILE")"
    abc="$(grep -c 'source=com.apple.keylayout.ABC' <<<"$seen" || true)"
    routes="$(grep -c 'input method routing: ok' <<<"$seen" || true)"
    repairs="$(grep -c 'pressing the previous-source shortcut' <<<"$seen" || true)"
    report "PROBE: $label current=$current bytes=$bytes abc=$abc routes=$routes repairs=$repairs"
    if [[ "$current" == "$expected" && "$bytes" == "$want" ]] \
        && { [[ "$routed" == 1 ]] || [[ "$abc" == 0 && "$routes" == 0 && "$repairs" == 0 ]]; }; then
        report "PASS: $label"
    else
        report "FAIL: $label: expected $expected $want$([[ "$routed" == 1 ]] || echo ' without ABC, route or repair')"
        FAILED=1
    fi
}

# Selections from another process, as the utility makes them. A non-KeyHue
# source first, so the utility does not route the ABC selection itself.
prepare_history() {
    local id
    for id in com.apple.inputmethod.Korean.2SetKorean "$@"; do
        "$WORKER" --keyhue-select-input-source "$id" || { report "FAIL: could not select $id"; exit 1; }
        sleep 0.3
    done
    sleep 0.7
}

run_toggle_checks() {
    start_window legacy
    # Menu selection opens the window's input method session (ADR 0061).
    choose_mode "$LATIN"
    choose_mode "$HANGUL"
    wait_for_logger
    # Before ADR 0071, setup selected Korean straight from ABC.
    prepare_history com.apple.keylayout.ABC "$HANGUL"
    toggle_and_type "ABC left as previous: the first press is routed to English" "$LATIN" 1
    toggle_and_type "after the route: Korean directly" "$HANGUL" 0
    toggle_and_type "after the route: English directly" "$LATIN" 0
    toggle_and_type "after the route: Korean directly again" "$HANGUL" 0
    # ADR 0071 setup: English, then Korean.
    prepare_history com.apple.keylayout.ABC "$LATIN" "$HANGUL"
    toggle_and_type "setup order: the first press goes to English directly" "$LATIN" 0
    toggle_and_type "setup order: Korean directly" "$HANGUL" 0
    stop_ghostty
}

if [[ "$TOGGLE" == 1 ]]; then
    run_toggle_checks
else
    for protocol in legacy kitty; do
        start_window "$protocol"
        # Menu selection opens the window's input method session (ADR 0061).
        choose_mode "$LATIN"
        choose_mode "$HANGUL"
        wait_for_logger
        check "$protocol: Hangul committed by Space" "'가 '" 15 40 49
        check "$protocol: Hangul kept on Tab" "'가'" 15 40 48
        check "$protocol: Hangul kept on Left" "'가'" 15 40 123
        check "$protocol: Hangul kept on Down" "'가'" 15 40 125
        check "$protocol: Hangul then period" "'가.'" 15 40 47
        check "$protocol: Tab without composition still reaches the program" "'가 \\t'" 15 40 49 48
        check "$protocol: Hangul after a kept Tab composes again" "'가가 '" 15 40 48 15 40 49
        probe "$protocol: Hangul then Return" 15 40 36
        probe "$protocol: Hangul then Escape" 15 40 53
        choose_mode "$LATIN"
        check "$protocol: Latin kept on Tab" "'ab'" 0 11 48
        check "$protocol: Latin kept on Right" "'ab'" 0 11 124
        if [[ "$CORRECTION" == 1 ]]; then
            if [[ "$protocol" == legacy ]]; then
                check_terminal_correction "$protocol" "15 4 2 5 40 2" "rhdgkd" "공항" 2
            else
                check_terminal_correction "$protocol" "5 40 15 15 16" "gkrry" "학교" 2
            fi
        fi
        stop_ghostty
    done
fi
if [[ "$CORRECTION" == 1 ]] && tail -c "+$(( IMK_LOG_MARK + 1 ))" "$IMK_LOG_FILE" 2>/dev/null | grep -q "reason=keyPermission"; then
    report "NOTE: allow KeyHue Input Method in System Settings → Privacy & Security → Accessibility, then run again"
fi
if [[ "$FAILED" == 0 ]]; then report "PASS: Ghostty input acceptance"; else report "FAIL: Ghostty input acceptance"; exit 1; fi
echo "==> results: $OUT"
