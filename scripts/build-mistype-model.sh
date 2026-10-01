#!/usr/bin/env bash
# 잘못된 언어 경고(ADR 0041)가 쓰는 한글 음절 모델을 한국어 위키백과 덤프로 만든다.
#
#   scripts/build-mistype-model.sh [최소 bigram 횟수=1]
#
# - 결과: Resources/Mistype/hangul-syllables.tsv (앱 번들에 들어간다, scripts/build-app.sh)
# - 원문: 한국어 위키백과 덤프의 첫 조각(일반 문서). 라이선스 CC BY-SA 4.0이므로 모델 파일도 같은 라이선스로 배포한다
#   (Resources/Mistype/LICENSE). 덤프는 .artifacts/corpora/에 내려받아 두고 다시 받지 않는다.
# - 날짜가 붙은 덤프는 몇 달 뒤 사라진다. 그때는 KOWIKI_DUMP를 새 날짜로 바꾸고 다시 만든 뒤
#   Tests/perf/mistype-eval.sh로 다시 잰다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 줄이지 않아도 1.8MB라 모두 남긴다. 크기를 줄이려면 값을 올리고 Tests/perf/mistype-eval.sh --prune으로 먼저 잰다.
MIN_BIGRAM="${1:-1}"
KOWIKI_DUMP="${KOWIKI_DUMP:-20260901}"
PART="kowiki-${KOWIKI_DUMP}-pages-articles1.xml-p1p82407.bz2"
URL="https://dumps.wikimedia.org/kowiki/${KOWIKI_DUMP}/${PART}"
CORPORA="${KEYHUE_CORPORA:-$ROOT/.artifacts/corpora}"
OUT="$ROOT/Resources/Mistype/hangul-syllables.tsv"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$CORPORA" "$(dirname "$OUT")"
if [[ ! -f "${CORPORA}/${PART}" ]]; then
    echo "==> 내려받기: ${URL}"
    curl -fSL -o "$WORK/${PART}" "${URL}"
    mv "$WORK/${PART}" "${CORPORA}/${PART}"
fi

echo "==> 빌드"
swiftc -O -parse-as-library -o "$WORK/build-mistype-model" \
    "$ROOT"/Sources/KeyHueCore/Mistype/*.swift "$ROOT/scripts/build-mistype-model.swift"

echo "==> 학습 (몇 분 걸린다)"
bunzip2 -c "${CORPORA}/${PART}" | "$WORK/build-mistype-model" "$OUT" "${MIN_BIGRAM}"
echo "==> ${OUT} ($(wc -c < "$OUT" | tr -d ' ') bytes)"
