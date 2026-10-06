#!/usr/bin/env bash
# KeyHue와 KeyHue 입력기를 이 Mac에서 완전히 지운다(ADR 0074). 처음 설치하는 사람의 상태로
# 되돌려 설치·권한·입력기 시나리오를 처음부터 검증할 때 쓴다.
#
#   scripts/uninstall.sh             # 지울 것을 보여 주고 확인을 받은 뒤 지운다
#   scripts/uninstall.sh --yes       # 묻지 않고 지운다
#   scripts/uninstall.sh --dry-run   # 지울 것만 보여 준다
#   scripts/uninstall.sh --check     # 남은 것이 있는지만 본다(없으면 0, 있으면 1)
#   scripts/uninstall.sh --no-backup # 설정·로그 백업을 남기지 않는다
#
# 지우는 것: 앱(/Applications, ~/Applications), 입력기(~/Library/Input Methods), 입력 소스 등록,
# 로그인 항목, 설정(defaults), 로그, Application Support·캐시, 개인정보 보호 권한
# (입력 모니터링·손쉬운 사용·이벤트 전송). KeyHue 설정에서 숨긴 macOS 입력 소스 표시는
# macOS 기본값(표시)으로 되돌린다.
# 지우지 않는 것: 서명 키(scripts/signing.sh), 저장소의 build/·.artifacts/, 셸 설정.
#
# 스크립트 테스트용: KEYHUE_APP_DIRS(앱을 찾을 폴더, ':'로 구분), KEYHUE_BACKUP_DIR, KEYHUE_PREPARE_TIMEOUT(초),
# LSREGISTER
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

BUNDLE_ID="io.github.sejoung.keyhue"
IME_BUNDLE_ID="io.github.sejoung.keyhue.inputmethod.spike"
# 이전 개발 빌드의 번들 ID. 설정만 남아 있을 수 있다.
LEGACY_DOMAINS=("ai.realdraw.KeyHue")
# KeyHue의 "macOS 입력 소스 표시 숨기기"가 쓰는 전역 키(SystemInputIndicator). 숨김이면 0이다.
INDICATOR_KEY="TSMLanguageIndicatorEnabled"

MODE=ask
BACKUP=1
for arg in "$@"; do
    case "$arg" in
        --yes) MODE=yes ;;
        --dry-run) MODE=dry ;;
        --check) MODE=check ;;
        --no-backup) BACKUP=0 ;;
        *) echo "usage: scripts/uninstall.sh [--yes | --dry-run | --check] [--no-backup]" >&2; exit 64 ;;
    esac
done

APP_DIRS="${KEYHUE_APP_DIRS:-/Applications:$HOME/Applications}"
IME_APP="$HOME/Library/Input Methods/KeyHueInputMethodSpike.app"
DOMAINS=("$BUNDLE_ID" "$IME_BUNDLE_ID" "${LEGACY_DOMAINS[@]}")

bundle_id_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true; }

# 이 KeyHue의 앱만: 같은 이름의 다른 앱은 지우지 않는다.
APPS=()
IFS=':' read -r -a dirs <<< "$APP_DIRS"
for dir in "${dirs[@]}"; do
    candidate="$dir/KeyHue.app"
    if [[ -d "$candidate" && ! -L "$candidate" ]]; then
        if [[ "$(bundle_id_of "$candidate")" == "$BUNDLE_ID" ]]; then
            APPS+=("$candidate")
        else
            echo "warning: $candidate 은(는) 다른 앱이라 건드리지 않습니다" >&2
        fi
    fi
done

FILES=()
if (( ${#APPS[@]} > 0 )); then FILES+=("${APPS[@]}"); fi
if [[ -d "$IME_APP" && "$(bundle_id_of "$IME_APP")" == "$IME_BUNDLE_ID" ]]; then FILES+=("$IME_APP"); fi
for id in "$BUNDLE_ID" "$IME_BUNDLE_ID"; do
    for path in "Library/Caches/$id" "Library/HTTPStorages/$id" "Library/HTTPStorages/$id.binarycookies" \
                "Library/Saved Application State/$id.savedState"; do
        [[ -e "$HOME/$path" ]] && FILES+=("$HOME/$path")
    done
done
for path in "Library/Application Support/KeyHue" "Library/Logs/KeyHue"; do
    [[ -e "$HOME/$path" ]] && FILES+=("$HOME/$path")
done

# `defaults delete` 뒤에도 빈 plist 파일이 남아 목록에 보인다. 파일도 남은 것으로 본다.
present_domains() {
    local all
    all="$(defaults domains 2>/dev/null | tr ',' '\n' | sed 's/^ *//;s/ *$//')"
    for domain in "${DOMAINS[@]}"; do
        if grep -qx "$domain" <<< "$all" || [[ -e "$HOME/Library/Preferences/$domain.plist" ]]; then echo "$domain"; fi
    done
}

# 서드파티 입력기는 com.apple.inputsources에 켜져 있다(InputMethodSourcePreferences와 같은 곳).
enabled_input_sources() {
    defaults read com.apple.inputsources AppleEnabledThirdPartyInputSources 2>/dev/null \
        | grep -oE "$IME_BUNDLE_ID(\.[A-Za-z]+)?" | sort -u || true
}

# 앱의 작업 모드를 시간 제한 안에서 실행한다. 이 모드를 모르는 이전 빌드는 플래그를 무시하고 앱으로
# 뜨므로, 시간 안에 끝나지 않으면 멈추고 124를 돌려준다. 출력은 APP_STEP_OUTPUT에 담긴다.
APP_STEP_OUTPUT=""
app_step() {
    local flag="$1" seconds="$2" log pid status=0
    log="$(mktemp)"
    "${APPS[0]}/Contents/MacOS/KeyHue" "$flag" > "$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 $(( seconds * 10 ))); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        status=124
    else
        wait "$pid" || status=$?
    fi
    APP_STEP_OUTPUT="$(cat "$log")"
    rm -f "$log"
    return $status
}

# 로그인 항목. 앱이 있으면 앱에 묻는다(SMAppService, 인증 없음). 앱을 지운 뒤나 이전 빌드에서만
# Background Task Management를 본다. `sfltool dumpbtm`은 부를 때마다 관리자 인증을 요구하므로
# 한 번 실행에 한 번만 부른다. 해제한 항목도 기록은 [disabled]로 남으니 켜진 것만 남은 것으로 본다.
login_item_registered() {
    if (( ${#APPS[@]} > 0 )) && [[ -d "${APPS[0]}" ]] && app_step --keyhue-login-item-status 5 \
        && [[ "$APP_STEP_OUTPUT" == "login item: "* ]]; then
        [[ "$APP_STEP_OUTPUT" == "login item: enabled" || "$APP_STEP_OUTPUT" == "login item: requiresApproval" ]]
        return
    fi
    sfltool dumpbtm 2>/dev/null | grep -B8 "Bundle Identifier: $BUNDLE_ID\$" | grep "Disposition:" | grep -q "\[enabled"
}

# macOS 26은 서드파티 모드 목록을 따로 둔다. 끈다고 답했는데 남거나 번들이 지워진 뒤 남은 항목은
# 이 도메인에서 KeyHue 항목만 뺀다(다른 입력기 항목은 그대로).
remove_stale_input_sources() {
    local filtered
    if [[ -n "${BACKUP_DIR:-}" ]]; then defaults export com.apple.inputsources "$BACKUP_DIR/com.apple.inputsources.plist" || true; fi
    filtered="$(mktemp)"
    defaults export com.apple.inputsources - | python3 -I -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
key = "AppleEnabledThirdPartyInputSources"
d[key] = [e for e in d.get(key, []) if e.get("Bundle ID") != sys.argv[1]]
sys.stdout.buffer.write(plistlib.dumps(d))' "$IME_BUNDLE_ID" > "$filtered" && defaults import com.apple.inputsources "$filtered"
    local status=$?
    rm -f "$filtered"
    return $status
}

# tccutil은 번들 ID를 LaunchServices로 찾는다. 지우기 전에, 있는 사본을 등록해 둔다.
bundle_path_for() {
    local id="$1" candidate
    local candidates=()
    if [[ "$id" == "$BUNDLE_ID" ]]; then
        candidates=("${APPS[@]+"${APPS[@]}"}" "$ROOT/build/KeyHue.app")
    else
        candidates=("$IME_APP")
        for candidate in "${APPS[@]+"${APPS[@]}"}" "$ROOT/build/KeyHue.app"; do
            candidates+=("$candidate/Contents/Helpers/KeyHueInputMethodSpike.app")
        done
    fi
    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" && "$(bundle_id_of "$candidate")" == "$id" ]]; then echo "$candidate"; return; fi
    done
}

# 남은 것을 한 줄씩. 개인정보 보호 권한은 사용자가 읽을 수 없어 여기서 보지 않는다.
leftovers() {
    local path domain source
    for path in "${FILES[@]+"${FILES[@]}"}"; do [[ -e "$path" ]] && echo "file: $path"; done
    while read -r domain; do [[ -n "$domain" ]] && echo "settings: $domain"; done < <(present_domains)
    while read -r source; do [[ -n "$source" ]] && echo "input source: $source"; done < <(enabled_input_sources)
    if login_item_registered; then echo "login item: $BUNDLE_ID"; fi
    if [[ "$(defaults read -g "$INDICATOR_KEY" 2>/dev/null || true)" == 0 ]]; then
        echo "system setting: $INDICATOR_KEY=0 (macOS 입력 소스 표시 숨김)"
    fi
    if pgrep -x KeyHue >/dev/null 2>&1; then echo "process: KeyHue"; fi
    if pgrep -x KeyHueInputMethodSpike >/dev/null 2>&1; then echo "process: KeyHueInputMethodSpike"; fi
    return 0
}

if [[ "$MODE" == check ]]; then
    LEFT="$(leftovers)"
    if [[ -z "$LEFT" ]]; then echo "==> KeyHue가 남긴 것이 없습니다"; exit 0; fi
    echo "==> 남아 있는 것:"; echo "$LEFT" | sed 's/^/    /'; exit 1
fi

echo "==> 지울 것"
LEFT="$(leftovers)"
if [[ -n "$LEFT" ]]; then echo "$LEFT" | sed 's/^/    /'; else echo "    (파일·설정·입력 소스·로그인 항목 없음)"; fi
echo "    privacy: $BUNDLE_ID, $IME_BUNDLE_ID 의 모든 권한 항목 초기화(입력 모니터링·손쉬운 사용 등)"
if [[ "$MODE" == dry ]]; then echo "==> --dry-run: 아무것도 지우지 않았습니다"; exit 0; fi
if [[ "$MODE" == ask ]]; then
    ( : < /dev/tty ) 2>/dev/null || { echo "error: 확인할 터미널이 없습니다. --yes로 실행하세요" >&2; exit 64; }
    printf '계속할까요? 되돌릴 수 없습니다 [y/N] ' > /dev/tty
    read -r answer < /dev/tty
    [[ "$answer" == y || "$answer" == Y ]] || { echo "==> 취소했습니다"; exit 1; }
fi

FAILED=0
step_failed() { echo "    FAIL: $1" >&2; FAILED=1; }

# 1. 앱 프로세스 안에서만 할 수 있는 일: 입력 모드 벗어나기, 입력 소스 끄기, 로그인 항목 해제.
echo "==> 입력 소스·로그인 항목 해제"
if (( ${#APPS[@]} > 0 )); then
    PREPARE_STATUS=0
    app_step --keyhue-prepare-uninstall "${KEYHUE_PREPARE_TIMEOUT:-10}" || PREPARE_STATUS=$?
    if (( PREPARE_STATUS == 124 )); then
        step_failed "앱이 해제 단계를 끝내지 않았습니다. 이 단계가 없는 이전 빌드일 수 있습니다: scripts/install.sh로 새 빌드를 설치한 뒤 다시 실행하세요"
    else
        if [[ -n "$APP_STEP_OUTPUT" ]]; then echo "$APP_STEP_OUTPUT" | sed 's/^/    /'; fi
        if ! grep -q "leave KeyHue input mode" <<< "$APP_STEP_OUTPUT"; then
            step_failed "앱이 해제 단계를 실행하지 않았습니다(이전 빌드이거나 이미 실행 중인 앱으로 넘어감). scripts/install.sh로 새 빌드를 설치한 뒤 다시 실행하세요"
        elif (( PREPARE_STATUS != 0 )); then
            step_failed "앱의 해제 단계"
        fi
    fi
else
    echo "    (앱이 없어 건너뜀)"
    if [[ -n "$(enabled_input_sources)" ]]; then
        step_failed "KeyHue 입력 소스가 켜져 있습니다. 시스템 설정 › 키보드 › 입력 소스에서 직접 빼세요"
    fi
fi

# 2. 실행 중인 앱과 입력기를 끝낸다.
echo "==> 실행 중인 KeyHue·입력기 종료"
if pgrep -x KeyHue >/dev/null 2>&1; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x KeyHue >/dev/null 2>&1 || break; sleep 0.5; done
    pkill -x KeyHue 2>/dev/null || true
fi
pkill -x KeyHueInputMethodSpike 2>/dev/null || true

# 3. 백업: 설정과 로그만. 앱·입력기는 다시 설치할 수 있다.
DOMAINS_PRESENT=()
while read -r domain; do [[ -n "$domain" ]] && DOMAINS_PRESENT+=("$domain"); done < <(present_domains)
if (( BACKUP == 1 )); then
    BACKUP_DIR="${KEYHUE_BACKUP_DIR:-$HOME/KeyHue-uninstall-backup-$(date +%Y%m%d-%H%M%S)}"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    for domain in "${DOMAINS_PRESENT[@]+"${DOMAINS_PRESENT[@]}"}"; do
        defaults export "$domain" "$BACKUP_DIR/$domain.plist" || step_failed "설정 백업 $domain"
    done
    if [[ -d "$HOME/Library/Logs/KeyHue" ]]; then cp -R "$HOME/Library/Logs/KeyHue" "$BACKUP_DIR/Logs"; fi
    INDICATOR="$(defaults read -g "$INDICATOR_KEY" 2>/dev/null || true)"
    if [[ -n "$INDICATOR" ]]; then echo "$INDICATOR_KEY=$INDICATOR" > "$BACKUP_DIR/global-settings.txt"; fi
    echo "==> 백업: $BACKUP_DIR"
fi

# 4. 개인정보 보호 권한. 번들을 지우기 전에: tccutil은 지운 번들의 ID를 찾지 못한다.
echo "==> 권한 초기화"
for id in "$BUNDLE_ID" "$IME_BUNDLE_ID"; do
    path="$(bundle_path_for "$id")"
    if [[ -n "$path" ]]; then "$LSREGISTER" -f "$path" >/dev/null 2>&1 || true; fi
    # All: 입력 모니터링·손쉬운 사용·이벤트 전송과, macOS가 따로 만든 항목(전체 디스크 접근 거부 등)까지.
    if tccutil reset All "$id" >/dev/null 2>&1; then
        echo "    $id"
    elif [[ -z "$path" ]]; then
        echo "    $id (번들을 찾지 못해 초기화하지 못함: 시스템 설정에서 직접 빼세요)"
    else
        echo "    $id (항목 없음 또는 초기화 실패)"
    fi
    # 저장소 빌드는 ID를 찾는 데만 썼다.
    if [[ "$path" == "$ROOT/build/"* ]]; then "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true; fi
done

# 5. 파일과 설정.
echo "==> 파일 삭제"
for path in "${FILES[@]+"${FILES[@]}"}"; do
    if [[ -e "$path" ]]; then rm -rf "$path" && echo "    $path" || step_failed "삭제 $path"; fi
done
echo "==> 설정 삭제"
for domain in "${DOMAINS_PRESENT[@]+"${DOMAINS_PRESENT[@]}"}"; do
    defaults delete "$domain" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$domain.plist"
    if defaults read "$domain" >/dev/null 2>&1; then step_failed "설정 $domain"; else echo "    $domain"; fi
done
if [[ "$(defaults read -g "$INDICATOR_KEY" 2>/dev/null || true)" == 0 ]]; then
    # 키를 지우면 macOS 기본값(표시)이다. SystemInputIndicator의 "다시 표시"와 같다.
    defaults delete -g "$INDICATOR_KEY" >/dev/null 2>&1 && echo "    macOS 입력 소스 표시: 기본값(표시)" || step_failed "macOS 입력 소스 표시 복원"
fi
if [[ -n "$(enabled_input_sources)" ]]; then
    echo "==> 남은 입력 소스 항목 정리"
    if remove_stale_input_sources; then echo "    $IME_BUNDLE_ID"; else step_failed "입력 소스 목록 정리"; fi
fi

echo "==> 확인"
LEFT="$(leftovers)"
if [[ -n "$LEFT" ]]; then
    echo "    남아 있는 것:"; echo "$LEFT" | sed 's/^/      /'
    FAILED=1
else
    echo "    남은 것 없음. 시스템 설정 › 개인정보 보호 및 보안의 목록에서 KeyHue가 빠졌는지도 확인하세요."
fi
if (( FAILED == 1 )); then exit 1; fi
echo "==> 완료. 다시 설치하려면 scripts/install.sh"
