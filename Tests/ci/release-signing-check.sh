#!/usr/bin/env bash
# 릴리즈 서명 경로를 일회용 키로 미리 돌려 본다(ADR 0021, 0022). CI 전용.
#
# release.yml과 같은 순서: 키 → base64(Secrets 흉내) → ci-import-signing.sh → package.sh → 요구 조건 확인 → 정리
# v0.1.3 릴리즈가 신뢰 설정 단계(-60005)에서 실패한 것을 PR 단계에서 잡기 위한 작업이다.
# 로컬에서는 키체인 검색 목록을 바꾸므로 기본적으로 실행하지 않는다(--force로 강제).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -z "${CI:-}" && "${1:-}" != "--force" ]]; then
    echo "CI 전용입니다(키체인 검색 목록을 바꿉니다). 로컬에서 강제로 돌리려면 --force" >&2
    exit 64
fi

export RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}"
KEYS="$RUNNER_TEMP/throwaway-keys"
OUTPUT="$RUNNER_TEMP/signing-output"
rm -rf "$KEYS" "$OUTPUT"
trap 'scripts/ci-import-signing.sh --cleanup' EXIT

echo "==> 일회용 키 생성"
KEYHUE_SIGNING_DIR="$KEYS" scripts/signing.sh generate
KEYHUE_SIGNING_P12="$(base64 -i "$KEYS/signing.p12" | tr -d '\n')"
KEYHUE_SIGNING_PASSWORD="$(cat "$KEYS/signing.password")"
export KEYHUE_SIGNING_P12 KEYHUE_SIGNING_PASSWORD
EXPECTED="$(/usr/bin/openssl pkcs12 -in "$KEYS/signing.p12" -nokeys -passin "file:$KEYS/signing.password" 2>/dev/null \
    | /usr/bin/openssl x509 -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"

echo "==> ci-import-signing.sh"
GITHUB_OUTPUT="$OUTPUT" scripts/ci-import-signing.sh
IDENTITY="$(sed -n 's/^identity=//p' "$OUTPUT")"
[[ -n "$IDENTITY" ]] || { echo "error: identity가 출력되지 않았습니다" >&2; exit 1; }

echo "==> package.sh (identity $IDENTITY)"
CODESIGN_IDENTITY="$IDENTITY" scripts/package.sh

echo "==> 서명 요구 조건 확인"
REQUIREMENT="$(codesign -d -r- build/KeyHue.app 2>&1 | grep designated)"
echo "    $REQUIREMENT"
[[ "$REQUIREMENT" == *"certificate leaf = H\"$EXPECTED\""* ]] || { echo "error: 일회용 키로 서명되지 않았습니다" >&2; exit 1; }
codesign --verify -R "=identifier \"io.github.sejoung.keyhue\" and certificate leaf = H\"$EXPECTED\"" build/KeyHue.app
echo "==> 릴리즈 서명 경로 정상"
