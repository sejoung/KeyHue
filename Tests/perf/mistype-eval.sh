#!/usr/bin/env bash
# 잘못된 언어로 친 단어 판정기(ADR 0040, 0041)의 오탐률·검출률을 공개 말뭉치로 잰다. 로컬 전용.
#
#   Tests/perf/mistype-eval.sh [mistype-eval 옵션...]
#
# - 모델은 앱에 들어가는 파일(Resources/Mistype/hangul-syllables.tsv, 한국어 위키백과로 학습)을 그대로 쓴다.
#   없으면 scripts/build-mistype-model.sh로 먼저 만든다.
# - 측정 말뭉치는 처음 실행할 때 내려받아 .artifacts/corpora/에 둔다(git에 올리지 않음, 측정에만 쓰고 앱에 넣지 않음).
#     한글: Leipzig 한국어 뉴스 2022 100K, Tatoeba 한국어 문장(대화체). 학습(위키백과)과 출처가 다르다.
#     영문: Leipzig 영어 뉴스 2023 10K, 영어 위키백과 2016 10K, 이 저장소의 코드·스크립트
# - 영어 사전은 기본으로 NSSpellChecker(앱이 쓰는 것과 같은 시스템 사전). --lexicon /usr/share/dict/words로 바꿀 수 있다.
# - 내 입력과 비슷한 말뭉치를 더할 수 있다. 결과 폴더에만 남고 어디로도 보내지 않는다.
#     Tests/perf/mistype-eval.sh --latin shell=$HOME/.zsh_history --hangul notes=<내 글.txt>
# - 결과(report.md, summary.log)는 .artifacts/perf/mistype-eval/<시각>/에 남는다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORPORA="${KEYHUE_CORPORA:-$ROOT/.artifacts/corpora}"
LEIPZIG="https://downloads.wortschatz-leipzig.de/corpora"
TATOEBA="https://downloads.tatoeba.org/exports/per_language/kor/kor_sentences.tsv.bz2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=scripts/artifacts.sh
source "$ROOT/scripts/artifacts.sh"
OUT="$(artifacts_dir perf/mistype-eval)"
exec > >(tee "$OUT/summary.log") 2>&1

mkdir -p "$CORPORA"

# Leipzig 말뭉치 하나를 내려받아 문장 파일(<이름>-sentences.txt) 경로를 출력한다.
leipzig() {
    local name="$1" file="${CORPORA}/$1-sentences.txt"
    if [[ ! -f "${file}" ]]; then
        echo "==> 내려받기: ${name}" >&2
        curl -fsSL "${LEIPZIG}/${name}.tar.gz" | tar -xz -C "$WORK"
        mv "$WORK/${name}/${name}-sentences.txt" "${file}"
    fi
    echo "${file}"
}

tatoeba() {
    local file="${CORPORA}/kor_tatoeba-sentences.tsv"
    if [[ ! -f "${file}" ]]; then
        echo "==> 내려받기: Tatoeba 한국어" >&2
        curl -fsSL "${TATOEBA}" | bunzip2 > "${file}"
    fi
    echo "${file}"
}

MODEL="$ROOT/Resources/Mistype/hangul-syllables.tsv"
[[ -f "${MODEL}" ]] || "$ROOT/scripts/build-mistype-model.sh"
KO_NEWS="$(leipzig kor_news_2022_100K)"
KO_TATOEBA="$(tatoeba)"
EN_NEWS="$(leipzig eng_news_2023_10K)"
EN_WIKI="$(leipzig eng_wikipedia_2016_10K)"

# 이 저장소의 코드·스크립트: 영문 모드로 치는 식별자·명령의 예.
# 판정기 자신과 테스트, 입력기 조합·고침 테스트에는 일부러 영문 모드로 친 한글(dkssud 등)이 있으므로 뺀다.
CODE="$WORK/code.txt"
find "$ROOT/Sources" "$ROOT/Tests" "$ROOT/scripts" -type f \( -name '*.swift' -o -name '*.sh' \) \
    -not -path '*/Mistype/*' -not -path '*/KeyHueInputMethodSpikeCoreTests/*' -not -path '*/Tests/host/*' \
    -not -name 'MistypeDetectorTests.swift' -not -name 'mistype-eval.*' -print0 \
    | xargs -0 cat > "$CODE"

# 배포 예외 단어(ADR 0065·0067): 영문 단어는 영문 모드, 한글 단어는 한글 모드로 맞게 친 것이다.
# 기준을 바꿀 때마다 그대로 두는지 잰다.
REPORTED="$WORK/reported.txt"
grep -v '^#' "$ROOT/Resources/Mistype/reported-words.txt" | sed '/^[[:space:]]*$/d' > "$REPORTED" || true
LC_ALL=C grep -E '^[A-Za-z]+$' "$REPORTED" > "$WORK/reported-latin.txt" || true
LC_ALL=C grep -vE '^[A-Za-z]+$' "$REPORTED" > "$WORK/reported-hangul.txt" || true
REPORTED_ARGS=()
if [[ -s "$WORK/reported-latin.txt" ]]; then REPORTED_ARGS+=(--latin "reported=$WORK/reported-latin.txt"); fi
if [[ -s "$WORK/reported-hangul.txt" ]]; then REPORTED_ARGS+=(--hangul "reported=$WORK/reported-hangul.txt"); fi

echo "==> 빌드"
# 판정기는 KeyHueCore의 다른 타입(입력기 연동 ID 등)도 쓴다. Core는 AppKit 없이 컴파일된다.
find "$ROOT/Sources/KeyHueCore" -name '*.swift' -print0 > "$WORK/core-files"
xargs -0 swiftc -O -parse-as-library -o "$WORK/mistype-eval" \
    "$ROOT/Sources/KeyHueSystemLexicon/SystemEnglishLexicon.swift" "$ROOT/Tests/perf/mistype-eval.swift" < "$WORK/core-files"

echo "==> 측정"
"$WORK/mistype-eval" \
    --model "${MODEL}" \
    --hangul "news=${KO_NEWS}" --hangul "tatoeba=${KO_TATOEBA}" \
    --latin "news=${EN_NEWS}" --latin "wiki=${EN_WIKI}" --latin "code=${CODE}" "${REPORTED_ARGS[@]+"${REPORTED_ARGS[@]}"}" \
    --prefix-words system \
    --out "$OUT" \
    "$@"

echo
echo "결과: $OUT/report.md"
