# 0079. 앱 조정 책임을 나누고, 상태 조회와 감시 갱신을 분리한다

- 상태: Accepted
- 날짜: 2026-10-06
- 관련: [0003](0003-core-module-and-event-flow.md), [0022](0022-testing-strategy.md), [0033](0033-retry-accessibility-attach-while-launching.md), [0043](0043-edge-cases-from-code-review.md), [0065](0065-correct-all-apps-with-feedback.md), [0069](0069-input-method-tab-and-shorter-menu.md), [0075](0075-check-accessibility-only-for-features-that-use-it.md)

## 맥락

전체 코드 리뷰에서 `AppDelegate`가 앱 구성과 입력기 설치·제거, 고침 알림 처리를 함께 맡고, 설정 모델과 모든 탭이 한 파일에 있었다. 메뉴와 설정은 각자 쓰지 않는 동작까지 하나의 프로토콜로 요구했다. 기능 상태를 읽는 getter가 감시를 시작하거나 AX 구독을 바꾸기도 했다.

설정 창을 처음 만들 때 뷰의 초기값이 모델의 탭을 일반으로 덮어써 입력기 설정 메뉴에서 선택한 탭이 사라졌다. AX 등록에서는 `cannotComplete`만 실패로 처리하여 다른 오류도 구독 성공으로 보일 수 있었다.

## 결정

### 책임과 상태 소유권

- `AppDelegate`는 구성과 화면 표시를 연결한다. 입력기 설치·제거·중복 작업 방지는 `InputMethodLifecycleCoordinator`, 고침 실패·되돌림 알림과 기록 갱신은 `CorrectionFeedbackCoordinator`가 맡는다. UI 안내·재실행은 주입한 콜백으로 앱에 요청한다.
- 메뉴는 `StatusMenuActions`, 설정 모델은 `SettingsActions`에 의존한다. 실제 동작은 같은 `AppDelegate`에 연결한다.
- `SettingsModel`은 설정 변경과 선택한 탭을 소유한다. 창 컨트롤러, 루트 뷰, 각 탭과 공통 컴포넌트는 파일로 나눈다. `SettingsView` 생성은 탭을 바꾸지 않는다. 메뉴 진입과 스크린샷은 모델에서 탭을 지정한다.
- `refreshFeatureStatuses()`가 감시 상태를 명시적으로 갱신한다. 메뉴 열기와 설정의 상태 새로고침에서 이를 먼저 호출하고, 개별 getter는 현재 상태만 읽는다. AX 확인은 관련 기능이 켜진 경우에만 한다(0075).
- 순수 정책과 값 변환은 Core에 둔다. OS 객체의 수명과 부수 효과는 MainActor 클래스에서 조정한다. 상속 계층이나 모든 타입의 프로토콜화는 추가하지 않는다.

### 식별자와 AX 등록

- 입력기 번들·연결·한글/영문 모드 ID의 Swift 원본은 `InputMethodIntegration`이다. 유틸리티, IMK 서버와 키 전달 계약이 이를 사용한다. plist와 패키징 셸은 독립 배포 메타데이터로 유지하고, 번들 검사와 IMK `--self-check`에서 실제 값이 일치하는지 확인한다. 기존 등록 ID는 유지한다.
- 필요한 AX 알림이 **모두 등록된 경우에만** observer와 초기 상태를 저장한다. 중간 실패는 이미 등록한 알림을 되돌린다.
- `cannotComplete`와 그 밖의 등록 오류는 기존의 횟수 제한 안에서 재시도한다. `notificationUnsupported`는 해당 PID·용도에 대해 즉시 멈추고 붙은 것으로 취급하지 않는다. 앱이나 용도가 바뀌면 다시 시도할 수 있다. 이 오류 처리는 0033을 보완한다.
- 등록 실패의 이유와 알림 이름을 로그에 남긴다. 사용자 안내는 응답 없음으로 단정하지 않고 AX 알림 구독 실패를 설명한다. 앱·문서 내용은 읽지 않는다.

## 검증

- 기본 진입점은 `scripts/verify.sh`다. Swift 빌드·테스트, lint, 셸 회귀, 사이트, 서명된 앱 번들과 IMK self-check를 실행한다.
- 설정 변경은 `scripts/screenshots.sh --check`로 검사한다. 뷰 초기화가 `.inputMethod` 선택을 보존하는 회귀 테스트와 메뉴·설정 일치 테스트를 유지한다.
- AX 오류 분류와 기존 가짜 시간 재시도 테스트를 실행한다. 실제 환경에서는 `Tests/perf/ax-timeout.sh`와 `Tests/perf/window-switch-after-launch.sh`를 사용하며 권한·설정 미충족을 통과로 기록하지 않는다.
- 실제 IMK·TextEdit·Ghostty는 `docs/TESTING.md`의 선택형 host runner를 사용한다. 기본 IMK runner도 설치된 서비스와 이번 앱의 실행 파일이 다르면 시작 전에 실패한다. 업데이트 옵션을 사용하면 업데이트 뒤 다시 비교한다. 이 사전 조건은 가짜 명령을 사용하는 셸 테스트로 검사한다.
- host 검사는 원래 입력 소스·설정 목록·유틸리티 실행 상태 복원을 확인한다. 설치 제거 검사는 서비스와 모드가 없는 별도 계정용이므로, 모드가 이미 설치된 환경에서는 업데이트·재사용 검사를 선택한다.

실제 실행 중 TextEdit의 `front window` 배열 순서가 편집 후 실제 AX 메인·포커스 창과 달라지는 것을 확인했다. 테스트 문서가 둘 다 실제 대상으로 확인되었는데도 runner가 중단됐다. 문서 준비는 대상 창의 `AXMain`을 지정하고, 클릭 전 확인은 `AXMainWindow`, 각 키 전 확인은 기존 `AXFocusedWindow`를 사용한다. 실패를 건너뛰거나 첫 키를 재전송하지 않는다. AppleScript 구문 컴파일도 셸 회귀 검사에 포함한다. 실행별 성공·실패 근거는 [실제 앱 호환성 기록](../INPUT_METHOD_COMPATIBILITY.md)에 남긴다.

## 결과

설정 UI와 앱 조정을 각각 변경할 수 있고, 상태 조회 횟수로 감시 동작이 바뀌지 않는다. 일부 AX 알림만 등록된 상태를 성공으로 표시하지 않는다. 설치·고침 정책, 프로세스 간 개인정보 계약과 기존 기능의 기본값은 유지한다. host runner는 기본 검증에 포함하지 않으며 실제 환경 결과를 별도로 기록한다.

### 실행 확인 (2026-10-06)

- 최종 `scripts/verify.sh`: Swift 타깃별 180·600·288개 검사 결과, 셸 135개·사이트 34개, 빌드·서명된 번들·IMK self-check 통과 (`.artifacts/verify/20261006-181050/`). 기본 실행의 host 전용 두 검사는 비활성이고, 설치된 환경용 업데이트·재사용 검사는 host runner에서 별도로 통과했다. ShellCheck는 이 Mac에 없어 선택형 검사로 생략됐다.
- `scripts/screenshots.sh --check`: 설정·HUD 14장 모두 픽셀 차이 0% (`.artifacts/screenshots/20261006-175200/`). 화면 구성을 바꾸지 않아 기존 이미지를 유지한다.
- 실제 이번 앱 빌드의 `Tests/perf/window-switch-after-launch.sh 3`: 3회 모두 창 전환 2번 감지 (`.artifacts/perf/window-switch-after-launch/20261006-181516/`).
- `Tests/perf/ax-timeout.sh`: 기본 대기 1.518초, 0.25초 제한을 적용한 요청 0.275초로 0.5초 기준 통과 (`.artifacts/perf/ax-timeout/20261006-181536/`). 임시 창 전환 설정·원래 입력 소스·입력 소스 목록·유틸리티 실행 상태를 복원했다.
- IMK·TextEdit·Ghostty의 성공과 중단, 최초 IMK 전환의 간헐적 실패는 [호환성 기록](../INPUT_METHOD_COMPATIBILITY.md#2026-10-06-앱-책임-분리-회귀-검사-adr-0079)에 따로 남긴다.
- 추가 검증: Homebrew로 ShellCheck 0.11.0을 설치한 뒤 `KEYHUE_REQUIRE_SHELLCHECK=1 scripts/lint.sh`로 저장소 전체 셸 스크립트 검사를 통과했다. `Tests/scripts/run.sh test_lint`의 7개 회귀 검사도 통과했다 (`.artifacts/shellcheck/20261006-183219/`). 위 표준 검증에서 생략했던 ShellCheck 항목을 별도로 완료했다.
