#!/usr/bin/env bash
# 테스트 결과(로그·캡처·차이 이미지)를 남기는 폴더를 만든다. source해서 쓴다.
#
#   source scripts/artifacts.sh
#   OUT="$(artifacts_dir perf/app-switch-latency)"   # .artifacts/perf/app-switch-latency/<시각>/
#
# .artifacts/ (git에 올리지 않음)
#   <종류>/<시각>/     실행마다 한 폴더. 이전 기록도 남는다(종류마다 최근 ARTIFACTS_KEEP개, 기본 20, 최소 1).
#   <종류>/latest      그 종류의 마지막 실행
#   latest             종류와 상관없이 마지막 실행
# 저장소 루트의 TestResults → .artifacts/latest
#
# 스크립트 테스트용: KEYHUE_ARTIFACTS_ROOT(.artifacts 위치, TestResults는 그 옆에 만든다)

ARTIFACTS_ROOT="${KEYHUE_ARTIFACTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.artifacts}"

# Host runners: the lock screen selects ABC itself. A runner started then recorded it
# as the source to restore and left it selected after the unlock (2026-10-07 18:03).
keyhue_require_unlocked_screen() {
    if ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
        echo "The screen is locked; unlock it and run again." >&2
        return 1
    fi
}

artifacts_dir() {
    local kind="$1"
    local base="${ARTIFACTS_ROOT}/${kind}"
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    # 같은 초에 다시 실행해도 덮어쓰지 않는다.
    local name="${stamp}" n=2
    while [[ -e "${base}/${name}" ]]; do
        name="${stamp}-${n}"
        n=$((n + 1))
    done
    mkdir -p "${base}/${name}"
    ln -sfn "${name}" "${base}/latest"
    ln -sfn "${kind}/${name}" "${ARTIFACTS_ROOT}/latest"
    ln -sfn "$(basename "${ARTIFACTS_ROOT}")/latest" "$(dirname "${ARTIFACTS_ROOT}")/TestResults"
    artifacts_prune "${base}" "${name}"
    echo "${base}/${name}"
}

# KeyHue 로그 파일(~/Library/Logs/KeyHue/KeyHue.log, ADR 0036) 중 테스트하는 동안 쌓인 부분을 결과 폴더에 남긴다.
#   MARK="$(keyhue_log_mark)"   # 테스트 시작 전
#   keyhue_log_save "$OUT" "$MARK"   # 끝난 뒤 → $OUT/keyhue-file.log
KEYHUE_LOG_FILE="${KEYHUE_LOG_FILE:-$HOME/Library/Logs/KeyHue/KeyHue.log}"

keyhue_log_mark() {
    if [[ -f "${KEYHUE_LOG_FILE}" ]]; then
        wc -c < "${KEYHUE_LOG_FILE}" | tr -d ' '
    else
        echo 0
    fi
}

keyhue_log_save() {
    local out="$1" mark="$2"
    # 시작 위치를 잡기 전에 끝났으면 남기지 않는다(파일 전체를 복사하지 않도록).
    [[ -n "${mark}" && -f "${KEYHUE_LOG_FILE}" ]] || return 0
    local size
    size="$(wc -c < "${KEYHUE_LOG_FILE}" | tr -d ' ')"
    # 그사이 파일이 돌려 쓰였으면(작아졌으면) 새 파일 전체를 남긴다.
    (( size >= mark )) || mark=0
    tail -c "+$((mark + 1))" "${KEYHUE_LOG_FILE}" > "${out}/keyhue-file.log"
}

# 오래된 실행 폴더를 지운다. 이번 실행(current)과, 폴더 이름(시각) 순으로 최근 것을 합쳐 ARTIFACTS_KEEP개를 남긴다.
# 이번 실행은 이름 순서와 상관없이 지우지 않는다(같은 초의 -2 접미사가 지워진 뒤 이름이 다시 쓰일 수 있다).
artifacts_prune() {
    local base="$1" current="${2:-}" keep="${ARTIFACTS_KEEP:-20}"
    # 이번 실행 폴더는 항상 남긴다: 1보다 작거나 숫자가 아니면 1로 본다.
    if ! [[ "${keep}" =~ ^[0-9]+$ ]] || (( 10#${keep} < 1 )); then
        keep=1
    fi
    local runs=()
    local run
    while IFS= read -r run; do
        runs+=("${run}")
    done < <(find "${base}" -mindepth 1 -maxdepth 1 -type d -name '20*' -exec basename {} \; | sort | grep -vxF -- "${current:-/}")
    if [[ -n "${current}" ]]; then keep=$(( keep - 1 )); fi
    local extra=$(( ${#runs[@]} - keep ))
    local i
    for (( i = 0; i < extra; i++ )); do
        rm -rf "${base:?}/${runs[i]}"
    done
}
