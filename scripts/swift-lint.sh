#!/usr/bin/env bash
# Swift 정적 검사(ADR 0080)
#
# 1. SwiftLint(.swiftlint.yml): 파일 길이(350줄 경고, 400줄 오류)와 함수 안의 쓰지 않는 코드
# 2. Periphery(.periphery.yml): 쓰지 않는 선언(데드 코드). 인덱스를 위해 .build/lint에 따로 빌드한다.
# 3. Tools/CodeCheck: 클래스 클로저의 강한 self 캡처(참조 순환), 모듈 안 타입 간 의존 순환
#
# SwiftLint·Periphery가 없으면 건너뛴다. KEYHUE_REQUIRE_SWIFT_LINT=1(CI)이면 실패한다.
# SWIFTLINT, PERIPHERY, CODE_CHECK로 실행 파일을 바꿀 수 있다(스크립트 자체 테스트용).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STATUS=0
SWIFTLINT="${SWIFTLINT:-swiftlint}"
PERIPHERY="${PERIPHERY:-periphery}"

missing() {
    if [[ -n "${KEYHUE_REQUIRE_SWIFT_LINT:-}" ]]; then
        echo "error: CI에서는 ${1}이(가) 필요합니다" >&2
        STATUS=1
    else
        echo "    (건너뜀: ${1}이(가) 없습니다. brew install ${1})"
    fi
}

echo "==> SwiftLint"
if command -v "$SWIFTLINT" >/dev/null 2>&1; then
    if "$SWIFTLINT" lint --quiet; then echo "    ok"; else STATUS=1; fi
else
    missing swiftlint
fi

echo "==> Periphery"
if command -v "$PERIPHERY" >/dev/null 2>&1; then
    swift build --build-tests --scratch-path .build/lint --enable-index-store --quiet
    STORE="$(find .build/lint -type d -path '*/index/store' -print -quit)"
    if [[ -z "$STORE" ]]; then
        echo "error: 인덱스 저장소를 찾지 못했습니다(.build/lint)" >&2
        STATUS=1
    elif "$PERIPHERY" scan --config .periphery.yml --index-store-path "$STORE" --quiet; then
        echo "    ok"
    else
        STATUS=1
    fi
else
    missing periphery
fi

echo "==> 참조 순환·의존 순환"
if [[ -z "${CODE_CHECK:-}" ]]; then
    swift build --package-path Tools/CodeCheck --product code-check --quiet
    CODE_CHECK="$(swift build --package-path Tools/CodeCheck --show-bin-path)/code-check"
fi
MODULES=()
for dir in Sources/*/; do
    name="$(basename "$dir")"
    MODULES+=("$name=$dir")
done
MODULES+=("KeyHueInputMethodSpikeCore=Tools/InputMethodSpike/Core" "KeyHueInputMethodSpike=Tools/InputMethodSpike/App")
if "$CODE_CHECK" "${MODULES[@]}"; then
    echo "    ok"
else
    STATUS=1
fi

exit "$STATUS"
