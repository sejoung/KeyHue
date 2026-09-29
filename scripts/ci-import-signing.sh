#!/usr/bin/env bash
# GitHub Actions(macOS 러너)에서 KeyHue 서명 인증서를 임시 키체인에 설치한다. (ADR 0021)
# 입력: KEYHUE_SIGNING_P12 (base64), KEYHUE_SIGNING_PASSWORD — 저장소 Secrets
# 출력: 인증서 SHA-1 해시. $GITHUB_OUTPUT이 있으면 identity=<해시>로 기록한다.
# 정리: scripts/ci-import-signing.sh --cleanup
#
# 인증서를 "신뢰"로 등록하지 않는다. 러너(macOS 15)에서는 root로도 신뢰 설정이 거부되고(-60005),
# codesign은 이름 대신 SHA-1 해시로 지정하면 신뢰되지 않은 자체 서명 인증서로도 서명한다.
# 사용자 Mac의 권한 판단(요구 조건 검사)도 신뢰와 무관하게 동작한다.
set -euo pipefail

KC="${RUNNER_TEMP:-/tmp}/keyhue-signing.keychain-db"
NAME="KeyHue Development"

if [[ "${1:-}" == "--cleanup" ]]; then
    security delete-keychain "$KC" 2>/dev/null || true
    exit 0
fi

: "${KEYHUE_SIGNING_P12:?secret KEYHUE_SIGNING_P12 is empty}"
: "${KEYHUE_SIGNING_PASSWORD:?secret KEYHUE_SIGNING_PASSWORD is empty}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '%s' "$KEYHUE_SIGNING_P12" | base64 --decode > "$WORK/signing.p12"

KC_PASSWORD="$(/usr/bin/openssl rand -hex 16)"
security create-keychain -p "$KC_PASSWORD" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PASSWORD" "$KC"
security import "$WORK/signing.p12" -k "$KC" -P "$KEYHUE_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASSWORD" "$KC" >/dev/null
# codesign이 이 키체인을 찾도록 검색 목록 앞에 둔다.
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')

HASH="$(security find-identity -p codesigning "$KC" | awk -v name="\"$NAME\"" 'index($0, name) {print $2; exit}')"
[[ -n "$HASH" ]] || { echo "::error::'$NAME' identity not found in the imported certificate" >&2; exit 1; }
echo "SHA-1: $HASH"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "identity=$HASH" >> "$GITHUB_OUTPUT"
exit 0
