#!/usr/bin/env bash
# GitHub Release 본문(Markdown)을 출력한다. 변경 내역은 release.sh가 만든 annotated 태그 메시지에서 가져온다.
#
#   scripts/release-notes.sh v0.2.0 > notes.md
set -euo pipefail

TAG="${1:?usage: release-notes.sh <tag>}"
VERSION="${TAG#v}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "error: 태그 $TAG가 없습니다" >&2; exit 1; }

# annotated 태그면 본문(변경 내역), 아니면 직전 태그부터의 커밋 제목
CHANGES="$(git tag -l --format='%(contents:body)' "$TAG" | sed '/^-----BEGIN PGP/,$d')"
if [[ -z "${CHANGES//[[:space:]]/}" ]]; then
    PREV="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$TAG^" 2>/dev/null || true)"
    CHANGES="$(git log --no-merges --pretty='- %s' ${PREV:+"$PREV..$TAG"} ${PREV:-"$TAG"})"
fi

SHA_FILE="build/dist/KeyHue-$VERSION.zip.sha256"
SHA="$( [[ -f "$SHA_FILE" ]] && cut -d' ' -f1 "$SHA_FILE" || echo "(see KeyHue-$VERSION.zip.sha256)")"

cat <<NOTES
## Changes

$CHANGES

## Install

1. Download **KeyHue-$VERSION.zip**, unzip it, and move **KeyHue.app** to **Applications**.
2. This build is **not signed with an Apple Developer ID and not notarized**, so macOS blocks it the first time you open it. To allow it:
   - **macOS 15 Sequoia or later**: open KeyHue once, then go to **System Settings › Privacy & Security** and click **Open Anyway**.
   - **macOS 13–14**: Control-click (right-click) KeyHue.app › **Open** › **Open**.
   - Or in Terminal: \`xattr -dr com.apple.quarantine /Applications/KeyHue.app\`
3. KeyHue appears in the menu bar (the chameleon icon). If you use *Switch on ESC* or *Switch when leaving a text field*, you may need to allow Input Monitoring / Accessibility again after each update.

<details>
<summary>한국어 설치 안내</summary>

1. **KeyHue-$VERSION.zip**을 내려받아 압축을 풀고 **KeyHue.app**을 **응용 프로그램** 폴더로 옮깁니다.
2. Apple Developer ID 서명·공증이 없는 빌드라서, 처음 열 때 macOS가 실행을 막습니다.
   - **macOS 15 이상**: KeyHue를 한 번 연 뒤 **시스템 설정 › 개인정보 보호 및 보안**에서 **그래도 열기**를 누릅니다.
   - **macOS 13–14**: KeyHue.app을 Control-클릭(우클릭) › **열기** › **열기**.
   - 또는 터미널에서: \`xattr -dr com.apple.quarantine /Applications/KeyHue.app\`
3. ESC 전환·텍스트 필드 전환 기능을 쓴다면, 업데이트할 때마다 입력 모니터링·손쉬운 사용 권한을 다시 허용해야 할 수 있습니다.

</details>

**SHA-256** (\`KeyHue-$VERSION.zip\`): \`$SHA\`

Universal build (Apple silicon + Intel), macOS 13 or later.
NOTES
