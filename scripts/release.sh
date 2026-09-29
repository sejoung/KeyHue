#!/usr/bin/env bash
# 버전을 올리고, 실제 빌드·테스트가 통과하면 커밋 + 태그를 만들어 push한다(ADR 0017).
#
#   scripts/release.sh patch            # 0.1.0 → 0.1.1
#   scripts/release.sh minor            # 0.1.3 → 0.2.0
#   scripts/release.sh major            # 0.9.2 → 1.0.0
#   scripts/release.sh 1.2.3            # 버전 직접 지정(현재보다 커야 함)
#
# 옵션
#   --dry-run    검사와 빌드·테스트만 하고 커밋/태그/push는 하지 않는다(작업 트리가 더러워도 진행)
#   --no-push    커밋과 태그까지만 만들고 push하지 않는다
#   -y, --yes    확인 질문 없이 진행한다
#
# 환경 변수
#   RELEASE_BRANCH   릴리즈를 허용할 브랜치 (기본: main)
#   RELEASE_REMOTE   push할 remote (기본: origin)
#
# 버전의 원본은 저장소 루트의 VERSION 파일이고, 태그는 v<버전> 형식이다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BRANCH="${RELEASE_BRANCH:-main}"
REMOTE="${RELEASE_REMOTE:-origin}"
DRY_RUN=0
PUSH=1
ASSUME_YES=0
BUMP=""

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

fail() {
    echo "error: $*" >&2
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        patch|minor|major) BUMP="$arg" ;;
        [0-9]*.[0-9]*.[0-9]*) BUMP="$arg" ;;
        --dry-run) DRY_RUN=1 ;;
        --no-push) PUSH=0 ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $arg" >&2; usage 64 ;;
    esac
done
[[ -n "$BUMP" ]] || usage 64

SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'

# semver 비교: $1 > $2 이면 0
version_gt() {
    local IFS=.
    local a=($1) b=($2) i
    for i in 0 1 2; do
        if (( 10#${a[i]} > 10#${b[i]} )); then return 0; fi
        if (( 10#${a[i]} < 10#${b[i]} )); then return 1; fi
    done
    return 1
}

next_version() {
    local current="$1" bump="$2"
    local IFS=.
    local parts=($current)
    local major=$((10#${parts[0]})) minor=$((10#${parts[1]})) patch=$((10#${parts[2]}))
    case "$bump" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        patch) echo "$major.$minor.$((patch + 1))" ;;
        *) echo "$bump" ;;
    esac
}

# ── 1. 저장소 상태 검사 ──────────────────────────────────────────────
[[ -f VERSION ]] || fail "VERSION 파일이 없습니다"
CURRENT="$(tr -d '[:space:]' < VERSION)"
[[ "$CURRENT" =~ $SEMVER ]] || fail "VERSION 파일 형식이 X.Y.Z가 아닙니다: '$CURRENT'"

NEXT="$(next_version "$CURRENT" "$BUMP")"
[[ "$NEXT" =~ $SEMVER ]] || fail "버전 형식이 X.Y.Z가 아닙니다: '$NEXT'"
version_gt "$NEXT" "$CURRENT" || fail "새 버전($NEXT)은 현재 버전($CURRENT)보다 커야 합니다"
TAG="v$NEXT"

CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
[[ "$CURRENT_BRANCH" == "$BRANCH" ]] || fail "릴리즈는 '$BRANCH' 브랜치에서만 합니다 (현재: '${CURRENT_BRANCH:-detached HEAD}')"

if [[ -n "$(git status --porcelain)" ]]; then
    if (( DRY_RUN )); then
        echo "warning: 작업 트리에 커밋하지 않은 변경이 있습니다 (dry-run이라 계속 진행)"
    else
        git status --short
        fail "커밋하지 않은 변경이 있습니다. 커밋하거나 stash한 뒤 다시 실행하세요"
    fi
fi

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "태그 ${TAG}가 이미 있습니다"

HAS_REMOTE=0
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
    HAS_REMOTE=1
    echo "==> fetch $REMOTE"
    git fetch --quiet --tags "$REMOTE"
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "태그 ${TAG}가 ${REMOTE}에 이미 있습니다"
    if git rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null; then
        BEHIND="$(git rev-list --count "HEAD..$REMOTE/$BRANCH")"
        (( BEHIND == 0 )) || fail "$REMOTE/${BRANCH}보다 ${BEHIND}개 커밋 뒤처져 있습니다. pull한 뒤 다시 실행하세요"
    fi
elif (( PUSH && ! DRY_RUN )); then
    fail "remote '$REMOTE'가 없습니다 (--no-push로 로컬 태그만 만들 수 있습니다)"
fi

# 직전 태그부터의 변경 내역(태그 메시지와 요약에 쓴다)
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [[ -n "$PREV_TAG" ]]; then
    CHANGES="$(git log --no-merges --pretty='- %s' "$PREV_TAG..HEAD")"
else
    CHANGES="$(git log --no-merges --pretty='- %s' HEAD)"
fi
[[ -n "$CHANGES" ]] || fail "직전 태그($PREV_TAG) 이후 커밋이 없습니다"

# ── 2. 확인 ────────────────────────────────────────────────────────
echo
echo "  KeyHue $CURRENT → $NEXT  ($TAG)"
echo "  branch: $BRANCH   remote: $([[ $HAS_REMOTE == 1 ]] && echo "$REMOTE" || echo '-')   push: $([[ $PUSH == 1 ]] && echo yes || echo no)$([[ $DRY_RUN == 1 ]] && echo '   [dry-run]')"
echo "  changes since ${PREV_TAG:-the beginning}:"
echo "$CHANGES" | sed 's/^/    /'
echo

if (( ! ASSUME_YES && ! DRY_RUN )); then
    [[ -t 0 ]] || fail "대화형 터미널이 아닙니다. --yes로 실행하세요"
    read -r -p "릴리즈를 진행할까요? [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "취소했습니다"; exit 1; }
fi

# ── 3. 실제 빌드 + 테스트 + 번들 ──────────────────────────────────────
echo "==> verify ($NEXT)"
VERSION="$NEXT" scripts/verify.sh

if (( DRY_RUN )); then
    echo
    echo "==> dry-run 완료: 검증 통과. 실제 릴리즈는 --dry-run 없이 실행하세요"
    echo "    (VERSION $CURRENT → $NEXT, 커밋 + 태그 $TAG$([[ $PUSH == 1 ]] && echo ", ${REMOTE}에 push"))"
    exit 0
fi

# ── 4. 버전 커밋 + 태그 ────────────────────────────────────────────
echo "$NEXT" > VERSION
git add VERSION
git commit --quiet -m "릴리즈 $TAG"
git tag -a "$TAG" -m "KeyHue $NEXT" -m "$CHANGES"
echo "==> committed and tagged $TAG ($(git rev-parse --short HEAD))"

# ── 5. push ────────────────────────────────────────────────────────
if (( PUSH )); then
    echo "==> push $REMOTE $BRANCH + $TAG"
    if ! git push --atomic "$REMOTE" "HEAD:refs/heads/$BRANCH" "refs/tags/$TAG"; then
        echo >&2
        echo "error: push에 실패했습니다. 로컬 커밋과 태그는 남아 있습니다." >&2
        echo "  다시 시도:  git push --atomic $REMOTE HEAD:refs/heads/$BRANCH refs/tags/$TAG" >&2
        echo "  되돌리기:   git tag -d $TAG && git reset --hard HEAD~1" >&2
        exit 1
    fi
else
    echo "==> push 생략. 나중에: git push --atomic $REMOTE HEAD:refs/heads/$BRANCH refs/tags/$TAG"
fi

echo
echo "==> KeyHue $NEXT 릴리즈 완료 ($TAG)"
if (( PUSH )) && [[ -f .github/workflows/release.yml ]]; then
    REPO_URL="$(git remote get-url "$REMOTE" | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')"
    echo "    GitHub Actions가 테스트 → universal 앱 → GitHub Release 게시를 진행합니다"
    echo "    진행 상황: $REPO_URL/actions   결과: $REPO_URL/releases/tag/$TAG"
fi
