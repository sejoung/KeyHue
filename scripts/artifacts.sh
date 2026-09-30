#!/usr/bin/env bash
# 테스트 결과(로그·캡처·차이 이미지)를 남기는 폴더를 만든다. source해서 쓴다.
#
#   source scripts/artifacts.sh
#   OUT="$(artifacts_dir perf/app-switch-latency)"   # .artifacts/perf/app-switch-latency/<시각>/
#
# .artifacts/ (git에 올리지 않음)
#   <종류>/<시각>/     실행마다 한 폴더. 이전 기록도 남는다(종류마다 최근 ARTIFACTS_KEEP개, 기본 20).
#   <종류>/latest      그 종류의 마지막 실행
#   latest             종류와 상관없이 마지막 실행
# 저장소 루트의 TestResults → .artifacts/latest
#
# 스크립트 테스트용: KEYHUE_ARTIFACTS_ROOT(.artifacts 위치, TestResults는 그 옆에 만든다)

ARTIFACTS_ROOT="${KEYHUE_ARTIFACTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.artifacts}"

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
    artifacts_prune "${base}"
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

# 오래된 실행 폴더를 지운다. 폴더 이름(시각) 순으로 최근 ARTIFACTS_KEEP개를 남긴다.
artifacts_prune() {
    local base="$1" keep="${ARTIFACTS_KEEP:-20}"
    local runs=()
    local run
    while IFS= read -r run; do
        runs+=("${run}")
    done < <(find "${base}" -mindepth 1 -maxdepth 1 -type d -name '20*' -exec basename {} \; | sort)
    local extra=$(( ${#runs[@]} - keep ))
    local i
    for (( i = 0; i < extra; i++ )); do
        rm -rf "${base:?}/${runs[i]}"
    done
}
