# 0022. 판단 로직은 Core로 모으고, 앱·스크립트·사이트·릴리즈 서명까지 자동 테스트한다

- 상태: Accepted (ADR 0003의 모듈 구성을 갱신)
- 날짜: 2026-09-29

## 맥락
커버리지를 재 보니 `KeyHueCore`(약 700줄)는 96%였지만, 앱(약 2,400줄)과 스크립트(약 740줄)에는 자동 테스트가 없었다. 실제로 겪은 문제는 대부분 그 영역에서 나왔다.

| 문제 | 발견 시점 |
|---|---|
| CI 인증서 신뢰 설정 실패(`-60005`) | v0.1.3 릴리즈가 게시되지 못함 |
| `signing.sh github`가 두 번째 값을 복사하자마자 클립보드를 비움 | 사용자 제보 |
| bash 3.2에서 `$REMOTE로`의 한글을 변수 이름으로 읽음 | 수동 테스트 |
| 설정 창 설명 문구가 "…"로 잘림 | 스크린샷을 만들다 우연히 |
| 앱 전환 직후 전환이 덮어써지고 색이 깜빡임 | 실행 로그 |

또 Core 안에서도 Caps Lock 색 경로(`color(for: .capsLock)`) 등이 한 번도 실행되지 않았다.

## 결정
### 구조
- 앱 코드를 라이브러리 `KeyHueApp`으로 옮기고, 실행 파일 `KeyHue`는 `KeyHueAppMain.run()`만 부른다. 그래야 테스트에서 앱 코드를 불러올 수 있다.
- 앱에 흩어진 **판단**을 Core로 옮기고, OS 연동은 주입한다.
  - `AutoResetCoordinator`
    - 앱 전환 시 이전 앱 기록 → 다시 읽기 → 정책 → 0.1초 지연 → 실행 직전 재확인 → 0.25초 뒤 검증 → 1회 재시도
    - `InputSourceSwitching`(앱: TIS, 테스트: 가짜)와 `Scheduling`(앱: main queue, 테스트: 가짜 시간)을 주입받는다
    - 덮어쓰기·재시도 시나리오를 결정적으로 재현한다
  - `PermissionPolicy`: 기능 상태(off/active/needsPermission), 시작 시 알릴 권한, "끄기" 동작
  - `StatusMenuState`: 메뉴 체크·표시·활성 상태와 전환 대상 이름. 앱은 그리기만 한다.
  - `FeatureStatus`, `PermissionKind`, `InputSourceInfo.displayName`도 Core로 옮긴다.

### 테스트 종류 (`docs/TESTING.md`)
1. **Core 단위**: 위 로직과 커버리지 빈틈(Caps Lock·알 수 없음 색, 저장, 빈 기본 입력 소스, 글리프 대체, 언어 이름 등).
2. **앱 통합**(`KeyHueAppTests`): 실제 화면에 State Bar 패널을 만들어 개수·위치·레벨·마우스 무시·색·불투명도·숨김을 확인한다. 이 밖에 실제 TIS 조회, 번역 번들 적용(`Localization.apply(_:in:)`), 설정 창 모델 바인딩, 앱 메뉴 단축키, 권한 설정 화면 URL.
3. **스크립트**(`Tests/scripts`, 순수 bash):
   - `release.sh`: 임시 git 저장소와 로컬 bare 원격으로 13개 시나리오. 검증 명령은 `KEYHUE_VERIFY_CMD`로 가짜로 바꾼다.
   - `signing.sh`: 키 파일 권한, base64 왕복, 가짜 `pbcopy`로 클립보드 순서.
   - `release-notes.sh`, `install.sh`: `KEYHUE_APP_SRC`, `KEYHUE_SKIP_QUIT`/`LAUNCH`로 실제 앱을 건드리지 않는다.
   - `lint.sh` 자체.
   - 테스트를 위해 추가한 훅은 환경 변수로만 켜지며 기본 동작은 그대로다.
4. **lint**(`scripts/lint.sh`): ShellCheck(warning 이상)와 "`$변수` 바로 뒤 한글" 검사. CI의 Ubuntu 작업에서는 ShellCheck가 필수다.
5. **사이트**(`Tests/site`, Node 내장 테스트): 데모 판정 로직(`assets/input-script.js`로 분리), 링크·이미지·앵커, 두 언어 설명서 목차.
6. **릴리즈 서명 경로**(`Tests/ci/release-signing-check.sh`): 일회용 키로 release.yml과 같은 순서를 PR마다 돌린다. 로컬에서는 키체인 검색 목록을 바꾸므로 `--force`로만 실행한다.
7. **설정 창 모양**(`scripts/screenshots.sh --check`): 다시 렌더링해 커밋된 이미지와 픽셀 비교(채널 차이 24 초과 픽셀이 0.5% 넘으면 실패, 차이 이미지 저장). macOS 버전별 렌더링 차이 때문에 CI에서는 돌리지 않는다.
8. **수동 체크리스트**(`docs/TESTING.md`): 권한 허용, Gatekeeper, 실제 키보드·모니터·전체 화면·노치, 성능.

`scripts/verify.sh`(release.sh와 CI가 사용)는 빌드 → Swift 테스트 → lint → 스크립트 → 사이트 → 번들을 모두 돈다.

### 하지 않는 것
- 메뉴바를 실제로 클릭하는 UI 자동화: 권한이 필요하고 결과가 불안정하다.
- 커버리지 목표 숫자 강제: 문제는 숫자가 아니라 테스트가 없는 영역에서 나왔다.

## 결과
- 테스트 수: Core 80 → 114, 앱 통합 0 → 19, 스크립트 0 → 31, 사이트 0 → 15. 여기에 CI 서명 경로 점검과 설정 창 모양 비교가 더해졌다.
- 테스트를 쓰는 과정에서 버그 두 개를 더 찾아 고쳤다.
  - `signing.sh github`: 저장소 밖에서 실행하면 `pipefail`로 아무 메시지 없이 종료됐다.
  - `MainMenu`: `NSApp`이 없을 때 강제 언래핑으로 죽었다.
- ShellCheck가 지적한 단어 분리 위험 4곳을 고쳤다(버전 파싱, 키체인 목록).
- 실제 앱에서 ESC·앱 전환 자동 전환이 Core 조정기를 거쳐 동작하는 것을 로그로 확인했다.
- 한계: CI 작업들(Ubuntu lint, macOS 통합 테스트, 서명 경로)은 GitHub 러너에서의 첫 실행으로 확인해야 한다.
