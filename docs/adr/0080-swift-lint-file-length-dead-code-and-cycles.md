# 0080. Swift 코드를 파일 길이·데드 코드·순환 참조로 검사한다

- 상태: Accepted
- 날짜: 2026-10-07
- 관련: [0022](0022-testing-strategy.md), [0079](0079-separate-app-coordination-and-explicit-status-refresh.md)

## 맥락

셸 스크립트에는 lint(`scripts/lint.sh`)가 있었지만 Swift 코드에는 없었다. `AppDelegate`는 0079로 책임을 일부 나눈 뒤에도 798줄이었고, 메뉴와 설정 창의 동작, 감시 켜기·끄기, 입력 전환 부품 연결, 실행 로그, Dock 표시를 함께 맡았다. 프로토콜이 바뀌면서 테스트용 가짜 객체에 쓰이지 않는 메서드가 남는 것처럼, 리뷰에서 데드 코드와 중복을 사람이 찾아야 했다.

## 결정

`scripts/swift-lint.sh`가 세 가지를 검사하고, `scripts/verify.sh`와 CI가 이를 실행한다.

1. **파일 길이(SwiftLint, `.swiftlint.yml`)**: `Sources`, `Tools/InputMethodSpike`, `Tools/CodeCheck/Sources`의 파일은 350줄부터 경고, 400줄을 넘으면 실패한다. 한 파일이 한 가지 책임만 지게 하려는 제약이다. 테스트 파일은 기능별로 길어지는 것이 자연스러워 보지 않는다. 함수 안의 쓰지 않는 코드(클로저 인자, `enumerated`, 옵셔널 바인딩, setter 값, 제어 흐름 레이블)도 같이 본다.
2. **데드 코드(Periphery, `.periphery.yml`)**: 테스트 타깃까지 인덱싱해 어디서도 쓰지 않는 선언을 찾는다. 인덱스는 `.build/lint`에 따로 빌드해 평소 빌드와 섞지 않는다. 저장되는 형식(Codable)의 필드와, 시스템이 정한 콜백 시그니처의 인자처럼 일부러 남기는 것은 이유와 함께 `// periphery:ignore`로 표시한다. `public` 범위가 넓은지는 보지 않는다.
3. **순환 참조(`Tools/CodeCheck`)**: swift-syntax로 소스를 읽는 저장소 전용 검사기다. 앱 패키지가 swift-syntax에 의존하지 않도록 따로 둔 패키지다.
   - **강한 참조 순환 후보**: 클래스·액터(와 그 확장)의 클로저가 `[weak self]`·`[unowned self]` 없이 `self`를 쓰면 실패한다. 저장되지 않거나 한 번 실행하고 놓는 호출(`map`, `Task`, `DispatchQueue.async`, SwiftUI `Binding` 등)과 즉시 호출하는 클로저는 넘긴다. 바깥 클로저가 `self`를 약하게 잡았고 `let self`로 다시 묶지 않았으면 안쪽 클로저의 `self`도 약한 참조로 본다. self보다 오래 살 수 없는 클로저는 `// code-check:ignore strong-self <이유>`로 표시한다.
   - **타입 간 의존 순환**: 한 모듈 안에서 최상위 타입끼리 서로를 참조하면 실패한다. 중첩 타입과 확장은 최상위 타입에 합친다. 한쪽이 프로토콜·클로저에 의존하게 하거나(의존성 역전) 공통 부분을 새 타입으로 뺀다. 모듈 간 순환은 SwiftPM이 이미 막는다.

SwiftLint·Periphery가 없으면 로컬에서는 건너뛰고, CI(`KEYHUE_REQUIRE_SWIFT_LINT=1`)에서는 실패한다. ShellCheck(0022)와 같은 방식이다.

### 도입하면서 고친 것

- 400줄을 넘던 파일을 책임별로 나눴다.
  - `AppDelegate`(798줄)는 구성 루트만 남겼다. 메뉴·설정 창의 요청 처리는 `AppActions`, 키보드·AX 감시와 기능 상태는 `FeatureMonitors`, 자동 전환·라우팅·세션 복구의 연결은 `InputSwitching`, 설치 뒤 처리는 `InputMethodSetup`, 실행 로그는 `LaunchDiagnostics`, 경고 표시는 `WrongLanguageWarningPresenter`, Dock·앱 메뉴는 `AppPresence`가 맡는다. 0079의 "실제 동작은 같은 `AppDelegate`에 연결한다"는 `AppActions`로 바뀐다.
  - `StatusBarController`에서 프로토콜(`FeatureActions.swift`), 표시 이름·색 대상(`InputDisplay.swift`), 메뉴 막대 아이콘(`StatusItemIcon`), 체크 표시·색 견본(`StatusMenuStyle.swift`), 정보 창(`AboutPanel`)을 뺐다.
  - 입력기의 `SpikeInputController`에서는 TIS 조회·표시 텍스트·세션 확인 알림(`SpikeClientText.swift`)과 자동 고침 처리(`SpikeAutomaticCorrection`)를 뺐다. `IMKShortcutCorrection`의 Backspace 보내기는 `TerminalKeyPostClient`로, `CorrectionProbe`의 클라이언트 프로토콜과 범위 해석은 `CorrectionProbeClient.swift`로 옮겼다.
  - 350줄 경고도 남기지 않았다. 가장 긴 파일은 348줄이다.
- 타입 순환 세 개를 끊었다. 입력기 번들 ID는 `InputMethodManager.bundleID` 별칭 대신 원본인 `InputMethodIntegration.bundleID`를 쓴다. 불리언 해석은 `StoredValue`로 옮겼다. 실패 알림은 `CorrectionFailureEvent(userInfo:)`로 읽는다.
- 쓰지 않는 선언을 지웠다(쓰지 않는 메서드·속성·enum case·인자·import, 할당만 하는 속성).
- 입력기의 클로저 네 개가 `self`를 강하게 잡던 것을 약한 참조로 바꾸거나 `self`가 필요 없게 했다.

## 검증

- `Tools/CodeCheck`의 자체 테스트(`swift test --package-path Tools/CodeCheck`)가 두 검사의 경계를 확인한다: 저장되는 클로저, `[self]`, 약한 참조, non-escaping·한 번 실행 호출, 값 타입·정적 멤버, 확장, 중첩 클로저, 표시 주석, 상호 참조, 프로토콜로 끊은 의존, 중첩 타입·확장 합치기, Tarjan 강결합 요소.
- `Tests/scripts/test_swift_lint.sh`가 가짜 도구로 건너뛰기·필수 실패·검사 실패 전달·모듈 목록을 확인한다.

## 결과

새 파일이 400줄을 넘거나, 쓰지 않는 선언이 남거나, 클로저가 `self`를 강하게 잡거나, 타입이 서로를 참조하면 PR에서 실패한다. 검사기는 문법만 보므로 클로저가 실제로 저장되는지는 알지 못한다. 넘기는 호출 목록과 표시 주석으로 조정한다. 350~400줄 파일은 경고로 보이며, 늘어나기 전에 나눈다.

### 실행 확인 (2026-10-07)

- `scripts/swift-lint.sh`: SwiftLint 경고·오류 0, Periphery 미사용 0, code-check 0. 분리하는 중에 `AppPresence`↔`StatusBarController` 순환을 이 검사가 잡아 정보 창을 따로 뺐다.
- `scripts/verify.sh`: Swift 180·600·289개, 셸 139개, 사이트 34개, 번들·IMK self-check 통과 (`.artifacts/verify/20261007-075817/`).
