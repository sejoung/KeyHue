#!/usr/bin/env bash
# KeyHue 코드 서명 키 관리 (ADR 0021)
#
# 모든 빌드(이 Mac, 다른 Mac, GitHub Actions 릴리즈)를 같은 자체 서명 인증서로 서명하면
# macOS가 업데이트·재빌드 후에도 같은 앱으로 보고 입력 모니터링·손쉬운 사용 권한을 유지한다.
#
#   scripts/signing.sh create [--replace]   키 생성 → ~/.config/keyhue/ 보관 → 이 Mac 키체인에 등록
#   scripts/signing.sh install              ~/.config/keyhue/의 키를 이 Mac 키체인에 등록 (다른 Mac에서)
#   scripts/signing.sh github               GitHub Secrets 등록 안내 (값을 클립보드로 복사)
#   scripts/signing.sh status               현재 상태
#
# 보관 위치(저장소 밖, 본인만 읽기 가능):
#   ~/.config/keyhue/signing.p12        인증서 + 비밀 키
#   ~/.config/keyhue/signing.password   p12 암호
# 이 두 파일은 절대 커밋하거나 공유하지 마세요. 가진 사람은 KeyHue인 척 서명할 수 있습니다.
# 다른 Mac으로 옮길 때는 두 파일을 안전한 방법(비밀번호 관리자 등)으로 복사한 뒤 install을 실행합니다.
set -euo pipefail

NAME="KeyHue Development"
DIR="${KEYHUE_SIGNING_DIR:-$HOME/.config/keyhue}"
P12="$DIR/signing.p12"
PASSFILE="$DIR/signing.password"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# macOS 기본 LibreSSL을 쓴다: 만든 p12를 macOS 키체인(로컬·CI)이 그대로 읽을 수 있다.
OPENSSL=/usr/bin/openssl
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

has_identity() {
    security find-identity -v -p codesigning | grep -q "\"$NAME\""
}

fingerprint() {
    "$OPENSSL" pkcs12 -in "$P12" -nokeys -passin "file:$PASSFILE" 2>/dev/null \
        | "$OPENSSL" x509 -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':'
}

cmd_create() {
    local replace=0
    [[ "${1:-}" == "--replace" ]] && replace=1

    if [[ -f "$P12" ]]; then
        echo "이미 키 파일이 있습니다: $P12"
        echo "키체인 등록만 하려면: scripts/signing.sh install"
        exit 1
    fi
    if has_identity; then
        if (( ! replace )); then
            echo "키체인에 '$NAME'이 이미 있지만 키 파일($P12)이 없습니다."
            echo "GitHub·다른 Mac과 공유하려면 키 파일이 필요하므로 새로 만들어야 합니다:"
            echo "  scripts/signing.sh create --replace"
            exit 1
        fi
        echo "==> 기존 '$NAME' 인증서와 키를 키체인에서 삭제"
        local attempts=0
        while has_identity && (( attempts < 5 )); do
            security delete-identity -c "$NAME" "$KEYCHAIN" >/dev/null || true
            attempts=$((attempts + 1))
        done
        has_identity && { echo "error: 기존 인증서를 지우지 못했습니다. 키체인 접근에서 직접 삭제하세요." >&2; exit 1; }
    fi

    mkdir -p "$DIR"
    chmod 700 "$DIR"
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

    echo "==> 키와 인증서 생성 (RSA 2048, 20년)"
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 7300 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
    (umask 077 && "$OPENSSL" rand -hex 24 > "$PASSFILE")
    (umask 077 && "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
        -out "$P12" -passout "file:$PASSFILE")
    echo "    보관: $P12"

    cmd_install
}

cmd_install() {
    [[ -f "$P12" && -f "$PASSFILE" ]] || {
        echo "error: $P12 또는 ${PASSFILE}이 없습니다." >&2
        echo "  처음이면: scripts/signing.sh create" >&2
        echo "  다른 Mac이면: 두 파일을 $DIR/에 복사한 뒤 다시 실행" >&2
        exit 1
    }
    if has_identity; then
        echo "키체인에 '$NAME'이 이미 있습니다."
        cmd_status
        return
    fi
    echo "==> 이 Mac의 login 키체인에 등록"
    security import "$P12" -k "$KEYCHAIN" -P "$(cat "$PASSFILE")" -T /usr/bin/codesign >/dev/null
    "$OPENSSL" pkcs12 -in "$P12" -nokeys -passin "file:$PASSFILE" -out "$TMP/cert.pem" 2>/dev/null
    echo "==> 코드 서명용으로 신뢰 (macOS가 암호를 물으면 입력하세요)"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

    has_identity || { echo "error: 인증서를 코드 서명에 쓸 수 없습니다" >&2; exit 1; }
    echo "==> 완료. scripts/build-app.sh가 이제 '$NAME'으로 서명합니다."
    cmd_status
}

cmd_github() {
    [[ -f "$P12" && -f "$PASSFILE" ]] || { echo "error: 키 파일이 없습니다. 먼저 scripts/signing.sh create" >&2; exit 1; }
    local repo
    repo="$(git remote get-url origin 2>/dev/null | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
    local url="https://github.com/$repo/settings/secrets/actions"

    if command -v gh >/dev/null 2>&1; then
        echo "==> gh로 ${repo}에 Secrets 등록"
        base64 -i "$P12" | gh secret set KEYHUE_SIGNING_P12 --repo "$repo"
        gh secret set KEYHUE_SIGNING_PASSWORD --repo "$repo" < "$PASSFILE"
        echo "==> 완료. 다음 릴리즈부터 이 인증서로 서명됩니다."
        return
    fi

    echo "GitHub 저장소에 Repository secret 두 개를 등록합니다: $url"
    echo "(New repository secret → Name 입력 → Secret에 붙여넣기 → Add secret)"
    echo
    # 값마다: 복사 → 사용자가 GitHub에 붙여넣고 등록 → Enter. 마지막에만 클립보드를 비운다.
    base64 -i "$P12" | tr -d '\n' | pbcopy
    echo "1/2  KEYHUE_SIGNING_P12 값을 클립보드에 복사했습니다."
    read -r -p "     Name: KEYHUE_SIGNING_P12 로 붙여넣고 [Add secret]을 누른 뒤 Enter " _

    tr -d '\n' < "$PASSFILE" | pbcopy
    echo "2/2  KEYHUE_SIGNING_PASSWORD 값을 클립보드에 복사했습니다."
    read -r -p "     Name: KEYHUE_SIGNING_PASSWORD 로 붙여넣고 [Add secret]을 누른 뒤 Enter " _

    printf '' | pbcopy
    echo
    echo "클립보드를 비웠습니다. 다음 릴리즈부터 이 인증서로 서명됩니다."
}

cmd_status() {
    echo "키 파일:   $([[ -f "$P12" ]] && echo "$P12" || echo "없음")"
    [[ -f "$P12" && -f "$PASSFILE" ]] && echo "지문(SHA-1): $(fingerprint)"
    if has_identity; then
        echo "키체인:    $(security find-identity -v -p codesigning | grep "\"$NAME\"" | sed 's/^ *//')"
    else
        echo "키체인:    없음 (빌드는 ad-hoc 서명 → 재빌드마다 권한이 풀립니다)"
    fi
}

case "${1:-}" in
    create) shift; cmd_create "$@" ;;
    install) cmd_install ;;
    github) cmd_github ;;
    status) cmd_status ;;
    *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
