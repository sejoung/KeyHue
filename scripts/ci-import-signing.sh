#!/usr/bin/env bash
# GitHub Actions(macOS 러너)에서 KeyHue 서명 인증서를 임시 키체인에 설치한다. (ADR 0021)
# 입력: KEYHUE_SIGNING_P12 (base64), KEYHUE_SIGNING_PASSWORD — 저장소 Secrets
# 출력: 성공하면 "KeyHue Development"로 codesign 가능. 정리는 scripts/ci-import-signing.sh --cleanup
set -euo pipefail

KC="${RUNNER_TEMP:-/tmp}/keyhue-signing.keychain-db"
NAME="KeyHue Development"
OPENSSL=/usr/bin/openssl   # 러너 PATH의 OpenSSL 3 대신 macOS 기본 LibreSSL (p12 형식 호환)

if [[ "${1:-}" == "--cleanup" ]]; then
    security delete-keychain "$KC" 2>/dev/null || true
    exit 0
fi

: "${KEYHUE_SIGNING_P12:?secret KEYHUE_SIGNING_P12 is empty}"
: "${KEYHUE_SIGNING_PASSWORD:?secret KEYHUE_SIGNING_PASSWORD is empty}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '%s' "$KEYHUE_SIGNING_P12" | base64 --decode > "$WORK/signing.p12"
printf '%s' "$KEYHUE_SIGNING_PASSWORD" > "$WORK/password"

KC_PASSWORD="$("$OPENSSL" rand -hex 16)"
security create-keychain -p "$KC_PASSWORD" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PASSWORD" "$KC"
security import "$WORK/signing.p12" -k "$KC" -P "$KEYHUE_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASSWORD" "$KC" >/dev/null
# codesign이 이 키체인을 찾도록 검색 목록 앞에 둔다.
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')

# 자체 서명 인증서를 코드 서명용으로 신뢰(관리자 도메인). 러너에서는 사용자 상호작용 없이 허용하도록 먼저 권한을 연다.
"$OPENSSL" pkcs12 -in "$WORK/signing.p12" -nokeys -passin "file:$WORK/password" -out "$WORK/cert.pem" 2>/dev/null
sudo security authorizationdb write com.apple.trust-settings.admin allow >/dev/null
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$WORK/cert.pem"

security find-identity -v -p codesigning "$KC" | grep "\"$NAME\"" || { echo "::error::signing identity is not usable" >&2; exit 1; }
echo "SHA-1: $("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
