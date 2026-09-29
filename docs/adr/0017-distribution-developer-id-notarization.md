# 0017. 릴리즈는 semver 태그로 관리하고, 배포 바이너리는 Developer ID 서명 + notarization으로 만든다

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

### 배포 바이너리 (`scripts/notarize.sh`)
- **Developer ID Application 인증서 + hardened runtime + notarization + staple.** 보통 릴리즈 태그를 체크아웃한 상태에서 실행한다.
  1. universal(arm64 + x86_64) 빌드
  2. 보안 타임스탬프 포함 서명
  3. 서명 검증
  4. `ditto` zip
  5. `notarytool submit --wait`
  6. `stapler staple`
  7. `spctl` 확인
  8. 최종 zip과 SHA-256 출력
  - ad-hoc(`-`) 서명으로는 실행을 거부한다. `SKIP_NOTARIZE=1`이면 서명까지만 한다.
  - notary 자격 증명은 저장소가 아니라 키체인 프로필(`notarytool store-credentials`)에 둔다.
- `build-app.sh`는 실제 인증서일 때 `--timestamp`를 붙이고, ad-hoc일 때는 붙이지 않는다.
- 필요한 entitlement는 없다. TIS, NSWorkspace, CGEventTap(listen-only), AX는 hardened runtime에서 별도 entitlement 없이 동작하고, 권한은 TCC가 관리한다.
- **Mac App Store는 보류한다.** 샌드박스에서 다음이 허용되는지 확인하지 않았다.
  - `TISSelectInputSource`로 다른 앱의 입력 소스 전환
  - listen-only event tap(Input Monitoring)
  - 다른 앱 AX 관찰(텍스트 focus 기능은 샌드박스에서 불가능할 가능성이 높다)
  확인 후 별도 ADR로 결정한다.

## 결과
- 릴리즈는 명령 한 줄이고, 검증을 통과한 커밋에만 태그가 붙는다.
- 로컬 bare 저장소를 origin으로 둔 샌드박스에서 확인한 시나리오:
  - 정상 동작: dry-run, patch(0.1.0→0.1.1, 원격에 커밋과 태그 push, 앱 번들 버전 0.1.1), minor `--no-push`, major 계산
  - 거부: 작업 트리 변경, 다른 브랜치, 기존 태그, 원격보다 뒤처짐, 새 커밋 없음, 더 작은 버전
  - 테스트 실패: 버전·태그·push 모두 변경 없음
- Developer ID 서명 빌드는 서명 식별자가 고정되어 업데이트 후에도 TCC 권한이 유지된다.
- 인증서와 Apple Developer 계정이 필요하다. `notarize.sh`의 실제 공증은 아직 실행하지 않았다.
- 태그 push 시 CI(GitHub Actions)에서 공증·GitHub Release를 자동화하는 것과 자동 업데이트(Sparkle 등)는 후속 과제다.
