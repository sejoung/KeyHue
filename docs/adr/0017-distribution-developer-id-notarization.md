# 0017. 릴리즈는 semver 태그로 관리하고, 태그 push 시 GitHub Actions가 서명 없는 universal 빌드를 게시한다

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
- 버전이 빌드 스크립트 기본값(`0.1.0`)에 박혀 있었고, 릴리즈 절차가 없었다.
- 사용자 요구: "실제 빌드·테스트를 돌려서 문제없으면 git 태그로 push, patch/minor/major로 버전 관리".
- 지금까지는 ad-hoc 서명(ADR 0002)이라 다른 Mac에서 열면 Gatekeeper가 막고, 재빌드할 때마다 TCC 권한(Input Monitoring/Accessibility)이 풀렸다. 글로벌 출시에는 신뢰할 수 있는 서명과 공증이 필요하다.

## 결정
### 버전과 태그 (`scripts/release.sh`)
- 버전의 원본은 저장소 루트의 **`VERSION` 파일**(`X.Y.Z`)이고, 태그는 **`vX.Y.Z`** 형식이다. `build-app.sh`와 `notarize.sh`는 VERSION 파일을 읽는다. 빌드 번호는 커밋 수다.
- `scripts/release.sh <patch|minor|major|X.Y.Z> [--dry-run] [--no-push] [--yes]`
  1. **사전 검사**: `main` 브랜치인지, 작업 트리가 깨끗한지, 태그가 로컬/원격에 이미 있는지, 원격보다 뒤처지지 않았는지, 직전 태그 이후 커밋이 있는지, 새 버전이 현재보다 큰지
  2. 변경 내역(직전 태그 이후 커밋 제목)을 보여주고 확인을 받는다(`--yes`로 생략. 비대화형이면 `--yes` 필수)
  3. **실제 검증**: `VERSION=<새 버전> scripts/verify.sh` → build + test + `.app` 번들
  4. 통과하면 VERSION 파일을 바꾸고 `릴리즈 vX.Y.Z` 커밋 + annotated 태그(메시지에 변경 내역)를 만든다
  5. `git push --atomic origin HEAD:main vX.Y.Z` — 브랜치와 태그가 함께 올라가거나 둘 다 안 올라간다
  - 검증이 실패하면 아무것도 바꾸지 않는다. push가 실패하면 재시도·되돌리기 명령을 출력한다.
  - `--dry-run`은 검사와 검증까지만 한다. 작업 트리가 더러워도 경고만 하고 진행한다.
- 버전 규칙(semver): 호환이 깨지는 변경 major, 기능 추가 minor, 버그 수정 patch.

### 배포 바이너리 — GitHub Actions (`.github/workflows/release.yml`)
Apple Developer Program에 가입하지 않았으므로 **Developer ID 서명·공증 없이** 배포한다.
- `vX.Y.Z` 태그 push로 실행된다.
  1. 태그가 VERSION 파일과 같은지 확인한다(`release.sh`를 거치지 않은 태그를 막는다)
  2. `swift test`
  3. `scripts/package.sh`: universal(arm64 + x86_64) `.app`을 ad-hoc 서명으로 만들고, 아키텍처·번들 버전·서명을 확인한 뒤 `ditto` zip과 `.sha256`을 만든다
  4. `scripts/release-notes.sh`: 태그 메시지(변경 내역)에 설치 안내(영/한)와 SHA-256을 붙인다
  5. `gh release create --verify-tag`. 다시 실행하면 파일과 본문만 갱신한다
- 패키징과 노트 생성은 스크립트로 분리해 로컬에서도 같은 결과를 만들 수 있다. workflow는 이 스크립트들을 부르기만 한다.
- CI(`ci.yml`)는 PR과 main push만 담당하고, 태그는 Release workflow가 테스트한다(중복 실행 방지).
- **ad-hoc 서명의 영향**
  - Gatekeeper가 첫 실행을 막는다(실측: `spctl` → rejected). 릴리즈 노트와 README에 "그래도 열기"(macOS 15+), 우클릭 › 열기(13–14), `xattr -dr com.apple.quarantine` 안내를 둔다.
  - 업데이트할 때마다 서명 해시가 바뀌어 입력 모니터링·손쉬운 사용 권한을 다시 허용해야 할 수 있다. 권한이 필요 없는 기본 기능(상태 바, Caps Lock, 앱 전환)에는 영향이 없다.
  - Apple silicon은 서명이 없는 바이너리를 실행하지 않으므로 ad-hoc 서명은 반드시 한다.

### 나중에: Developer ID (`scripts/notarize.sh`)
Apple Developer 계정이 생기면 쓸 수 있도록 서명·공증 스크립트는 남겨 둔다.
- universal 빌드 → Developer ID 서명(보안 타임스탬프) → `notarytool submit --wait` → `stapler staple` → `spctl` 확인 → zip
- 필요한 entitlement는 없다.
- 전환하려면 인증서(.p12)와 notary 자격 증명을 GitHub Secrets에 넣고 Release workflow의 패키징 단계를 바꾸면 된다. 별도 ADR로 결정한다.
- **Mac App Store는 보류한다.** 샌드박스에서 다른 앱의 입력 소스 전환, listen-only event tap, 다른 앱 AX 관찰이 허용되는지 확인하지 않았다.

## 결과
- 릴리즈는 명령 한 줄이고, 검증을 통과한 커밋에만 태그가 붙는다.
- 로컬 bare 저장소를 origin으로 둔 샌드박스에서 확인한 시나리오:
  - 정상 동작: dry-run, patch(0.1.0→0.1.1, 원격에 커밋과 태그 push, 앱 번들 버전 0.1.1), minor `--no-push`, major 계산
  - 거부: 작업 트리 변경, 다른 브랜치, 기존 태그, 원격보다 뒤처짐, 새 커밋 없음, 더 작은 버전
  - 테스트 실패: 버전·태그·push 모두 변경 없음
- 로컬 재현: `scripts/package.sh`로 만든 universal zip의 아키텍처(x86_64 arm64), 번들 버전, ad-hoc 서명을 확인했다. 샌드박스 태그에서 workflow 단계(태그·VERSION 일치 검사, 테스트, 패키징, 노트 생성)를 재현했다.
- Release workflow 자체(`gh release create` 포함)는 GitHub에서 아직 실행해 보지 않았다. 첫 태그 push 결과로 확인해야 한다.
- 자동 업데이트(Sparkle 등)는 범위 밖이다. 도입하면 별도 ADR로 결정한다.

## 보완 (2026-10-03): 버전 형식
- 각 자리는 0이거나 0으로 시작하지 않는 수다(semver). `release.sh`의 버전 인자와 VERSION 파일, 빌드 스크립트가 읽는 `scripts/app-config.sh`의 VERSION 검사 모두 `01.3.0`·`0.01.0`을 거부한다. 앱의 업데이트 확인과 같은 규칙이다.
- 버전 인자는 하나만 받는다(`major patch`, `minor 0.3.0`). 이전에는 마지막 것을 조용히 썼다.
- 테스트: `test_rejects_leading_zeros_in_versions`, `test_rejects_leading_zeros_in_the_version_file`, `test_rejects_more_than_one_version_argument`.
