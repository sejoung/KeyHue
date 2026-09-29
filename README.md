# KeyHue — macOS Input State Utility

> macOS의 현재 입력 상태를 화면 가장자리 색으로 즉시 인지하고, 잘못된 한/영 입력을 줄여주는 가볍고 빠른 네이티브 유틸리티.

## 빌드 & 실행

요구 사항: macOS 13+, Xcode 16+ (Swift 6 toolchain). 외부 의존성 없음.

```bash
swift test                 # KeyHueCore 단위 테스트
scripts/build-app.sh       # build/KeyHue.app 생성 (release, ad-hoc 서명, docs/icon.png → AppIcon)
open build/KeyHue.app      # 메뉴바에 ⌨︎ 아이콘으로 실행 (Dock에는 표시되지 않음)
scripts/verify.sh          # build + test + bundle 일괄 검증, 로그는 TestResults/
```

- `swift run KeyHue`로도 실행할 수 있지만 Launch at Login은 `.app` 번들에서만 동작한다.
- ESC → ABC는 **Input Monitoring**, 텍스트 focus 해제 → ABC(실험적)는 **Accessibility** 권한이 필요하며, 해당 옵션을 켤 때만 요청한다.
- ad-hoc 서명은 재빌드할 때마다 서명이 바뀌므로 위 권한을 다시 허용해야 할 수 있다. `CODESIGN_IDENTITY="Apple Development: …" scripts/build-app.sh`로 고정 인증서를 쓰면 피할 수 있다.
- 설계 결정은 [docs/adr](docs/adr/README.md)에 기록한다.

```text
Sources/KeyHueCore   상태 모델·판정·정책·설정 (순수 로직, 테스트 대상)
Sources/KeyHue       AppKit/Carbon 런타임: Monitors, Overlay, HUD, 메뉴바
Tests/KeyHueCoreTests
scripts/             build-app.sh, make-icon.swift, verify.sh
docs/adr/            Architecture Decision Records
```

## 1. 제품 목표
KeyHue는 macOS 기본 입력 소스 표시의 낮은 가독성을 보완한다. 사용자가 타이핑하기 전에 현재 입력 상태가 **한글인지, 영문인지, Caps Lock인지** 시선을 옮기지 않고 알 수 있게 한다.

추가로 앱 전환이나 ESC 입력 같은 상황에서 입력 소스를 영문(ABC)으로 되돌려, 한글 상태가 남아 단축키나 명령 입력이 꼬이는 문제를 줄인다.

### 핵심 원칙
- **Lightweight**: 항상 실행해도 부담이 없어야 한다.
- **Native**: Swift + AppKit 중심.
- **Instant**: 입력 상태 변경이 체감상 즉시 반영.
- **Non-intrusive**: 마우스/키보드 입력을 방해하지 않는다.
- **Event-driven**: 고주기 polling을 피한다.
- **Privacy-first**: 입력한 문자 내용은 읽거나 저장하지 않는다.

---

## 2. MVP 기능

### 2.1 화면 하단 Input State Bar
현재 입력 상태에 따라 디스플레이 하단에 기본 3px 컬러 라인을 표시한다.

| 상태 | 기본 표시 |
|---|---|
| Korean | Green 계열 |
| English / ABC | Blue 계열 |
| Caps Lock | Red 계열 |

```text
┌─────────────────────────────────────────────┐
│                                             │
│                현재 사용 중인 앱            │
│                                             │
└━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┘
               KeyHue State Bar
```

라인은 클릭 이벤트를 받지 않는다.

```swift
window.ignoresMouseEvents = true
```

색상과 두께는 설정에서 변경 가능하게 한다.

### 2.2 실제 Input Source 상태 감지
키 입력으로 상태를 추측하지 않고 macOS에서 **실제로 선택된 Input Source**를 읽는다.

우선 검토 API:

```swift
TISCopyCurrentKeyboardInputSource()
```

입력 소스 변경 notification을 구독하여 이벤트 기반으로 갱신한다.

```text
Input Source 변경
        ↓
macOS Notification
        ↓
InputSourceMonitor
        ↓
현재 Source 확인
        ↓
Korean / English 판정
        ↓
Overlay 업데이트
```

사용자가 한/영 키를 눌렀더라도 실제 Input Source가 바뀌지 않았다면 **KeyHue의 색도 바뀌면 안 된다.** 이것이 전환 실패에 대한 즉각적인 피드백이 된다.

### 2.3 Caps Lock 상태
Caps Lock 상태를 별도로 감지한다.

```swift
NSEvent.modifierFlags.contains(.capsLock)
```

필요한 경우 global/local `flagsChanged` monitor를 사용한다.

우선순위:

```text
Caps Lock ON → CAPS 상태 표시
Caps Lock OFF → 현재 Input Source 상태 표시
```

### 2.4 앱 전환 시 ABC로 전환
옵션 기능. 사용자가 다른 앱으로 전환하면 입력 소스를 ABC로 변경한다.

```text
Slack (한글 입력 중)
        ↓ Cmd + Tab
VS Code
        ↓
ABC 자동 전환
        ↓
하단 라인 → English 색상
```

앱 변경 감지:

```swift
NSWorkspace.shared.notificationCenter
// didActivateApplicationNotification
```

설정:

```text
[✓] 앱 전환 시 English(ABC)로 전환
```

자동으로 사용자 상태를 변경하는 기능이므로 쉽게 끌 수 있어야 한다.

### 2.5 ESC → ABC
옵션 기능. ESC를 누르면 ABC 입력 소스로 변경한다.

특히 VS Code, Xcode, Terminal, iTerm, Vim/Neovim 등에서 유용하다.

```text
[✓] ESC를 누르면 English(ABC)로 전환
```

전역 ESC 감지를 위해 Event Tap 또는 Global Event Monitor 사용 여부를 구현 단계에서 검증한다. Accessibility/Input Monitoring 권한이 필요한 기능은 핵심 표시 기능과 분리한다.

---

## 3. Phase 2

### 입력 포커스 해제 시 ABC
텍스트 필드 focus가 사라졌을 때 English로 전환한다. 다른 앱의 UI focus 추적이 필요하므로 Accessibility API 사용 가능성이 높다. **MVP에는 넣지 않는다.**

### 앱별 Input Source 기억
Bundle Identifier별로 마지막 입력 상태를 기억하고 앱으로 돌아왔을 때 복원한다.

```text
Slack     → Korean
Terminal  → English
VS Code   → English
Notion    → Korean
```

### 전환 순간 HUD
상태 변경 순간 `가 / a / A`를 화면 중앙 하단에 약 300~700ms 표시한다. 평소에는 State Bar만 유지한다.

### 멀티 모니터 정책

```text
○ 모든 모니터에 표시
● 현재 활성 모니터만 표시
```

---

## 4. UX
KeyHue는 **메뉴바 앱**으로 동작하며 Dock에는 표시하지 않는 방향을 우선한다.

```text
LSUIElement = YES
```

메뉴 예시:

```text
KeyHue

Current Input     Korean

✓ Show State Bar
✓ Reset to ABC on App Switch
✓ Reset to ABC on ESC

Bar Thickness     3px
Colors...          >
Launch at Login

Quit KeyHue
```

### State Bar 기본값
- 높이: 3px
- 위치: 화면 최하단
- 애니메이션: 최소화
- 마우스 이벤트: 무시
- 그림자: 없음
- 텍스트: 없음

색상만으로 의미를 강제하지 않도록 향후 상태별 라인 패턴/두께 옵션도 검토한다.

---

## 5. 기술 스택
- macOS native application
- Swift
- AppKit
- Swift Package Manager
- 외부 dependency 최소화 또는 0

Overlay와 런타임 핵심은 AppKit으로 구현한다. 설정 화면은 필요하면 SwiftUI를 사용할 수 있다.

```text
AppKit
 ├─ NSStatusItem
 ├─ NSPanel / NSWindow
 ├─ NSWorkspace Notifications
 └─ NSEvent

Carbon / macOS Input Source API
 └─ TIS Input Source
```

---

## 6. 아키텍처

```text
KeyHueApp
│
├── InputSourceMonitor
│     ├── 현재 Input Source 조회
│     ├── Source 변경 감지
│     └── Korean / English 판정
│
├── CapsLockMonitor
│     └── Caps Lock 감지
│
├── AppFocusMonitor
│     └── 활성 Application 변경 감지
│
├── KeyboardMonitor
│     └── ESC 감지 (옵션)
│
├── InputSourceController
│     └── ABC Input Source로 전환
│
├── InputStateStore
│     └── 현재 상태 통합
│
├── OverlayController
│     ├── Screen 탐색
│     ├── Overlay window 관리
│     └── 색상/위치 업데이트
│
├── StatusBarController
│     └── 메뉴바 UI
│
└── SettingsStore
      └── UserDefaults
```

상태 모델:

```swift
enum InputState {
    case korean
    case english
    case capsLock
    case unknown
}
```

```text
macOS Events
     ↓
Monitors
     ↓
InputStateStore
     ↓
OverlayController
```

UI가 OS 이벤트를 직접 처리하지 않게 분리한다.

---

## 7. Overlay Window 구현
각 screen마다 borderless overlay window를 생성한다.

```swift
let window = NSWindow(
    contentRect: frame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)

window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = false
window.ignoresMouseEvents = true
```

Space / Full Screen 대응:

```swift
window.collectionBehavior = [
    .canJoinAllSpaces,
    .fullScreenAuxiliary,
    .stationary
]
```

Window level은 시스템 UI를 과도하게 덮지 않도록 실제 테스트 후 결정한다.

검증 대상:
- Safari/Chrome Full Screen
- VS Code/Xcode
- 다른 Space 이동
- Mission Control
- Dock/메뉴바 동작
- 외부 모니터 연결/해제

---

## 8. 성능 목표
항상 실행되는 앱이므로 리소스 사용을 최우선으로 한다.

**고주기 Timer polling 금지.**

```text
Input Source change → Notification
App switch          → NSWorkspace Notification
Caps Lock           → flagsChanged Event
Screen change       → Screen configuration Notification
```

Idle 목표:

```text
CPU       ≈ 0%
Memory    가능한 작게 유지
Disk I/O  없음
Network   없음
```

MVP에는 네트워크와 telemetry를 넣지 않는다.

---

## 9. Privacy
KeyHue는 사용자가 입력한 내용을 필요로 하지 않는다.

수집하지 않는 것:
- 실제 타이핑 문자열
- 클립보드
- 문서 내용
- 브라우저 URL
- 비밀번호

필요한 정보:

```text
현재 Input Source
Caps Lock 상태
활성 Application 변경 이벤트
ESC key event (옵션 활성화 시)
```

Keyboard monitor에서도 ESC 여부만 판단하며 다른 키를 저장/기록하지 않는다.

> **KeyHue never records what you type.**

---

## 10. 권한 전략
권한이 없어도 가능한 기능은 그대로 제공한다.

```text
기본 기능
✓ Input Source 표시
✓ Caps Lock 표시
✓ App 전환 감지

추가 권한 필요 가능
△ Global ESC 감지
△ Text Focus 감지
```

앱 시작 시 불필요한 Accessibility 권한을 요구하지 않는다. 해당 옵션을 사용자가 켰을 때만 필요한 권한을 설명하고 요청한다.

---

## 11. 설정 저장
DB 없이 `UserDefaults`를 사용한다.

```swift
struct KeyHueSettings {
    var showStateBar: Bool
    var resetOnAppSwitch: Bool
    var resetOnEscape: Bool
    var launchAtLogin: Bool
    var barHeight: CGFloat
    // koreanColor / englishColor / capsColor
}
```

---

## 12. Launch at Login
현대 macOS에서는 `ServiceManagement` API를 우선 사용한다.

```swift
SMAppService.mainApp
```

메뉴에서 사용자가 직접 켜고 끌 수 있게 한다.

---

## 13. MVP에서 하지 않을 것
- 계정/로그인
- 서버
- Cloud Sync
- Analytics
- 복잡한 animation
- 앱별 Rule Engine
- 텍스트 내용 분석
- AI 기능
- Accessibility 기반 text-focus tracking

초기 버전은 한 가지 문제에 집중한다.

> **내가 지금 한글을 치게 될지 영어를 치게 될지를 타이핑하기 전에 알 수 있다.**

---

## 14. 구현 순서

### Milestone 1 — Input Source
- 현재 Input Source 조회
- Korean / English 판정
- Source 변경 event 감지
- Console에서 상태 확인

완료 조건: ABC ↔ Korean 전환 시 즉시 정확한 상태가 출력된다.

### Milestone 2 — State Bar
- Borderless NSWindow/NSPanel
- 화면 하단 3px
- InputState에 따른 색상 변경
- Mouse event 무시

### Milestone 3 — Full Screen / Multi Screen
- 모든 Spaces
- Full Screen
- 외부 모니터 연결/해제
- 해상도 변경 대응

### Milestone 4 — Caps Lock
- Caps 상태 감지
- 별도 표시
- 해제 시 현재 Input Source 색 복원

### Milestone 5 — Menu Bar
- Show/Hide
- 앱 전환 ABC 옵션
- ESC ABC 옵션
- Launch at Login
- Quit

### Milestone 6 — Auto ABC
- 앱 전환 감지
- ABC Input Source 탐색
- 실제 Source 전환
- UI 동기화

### Milestone 7 — ESC
- Global ESC 감지
- 필요한 권한 확인
- 권한 없을 때 graceful fallback

---

## 15. 테스트 케이스

### Input Source
- ABC → Korean
- Korean → ABC
- 빠른 연속 전환
- Caps Lock ON/OFF
- 전환 키를 눌렀지만 실제 Source가 변경되지 않은 경우

### Applications
- Safari
- Chrome
- Slack
- VS Code
- Xcode
- Terminal
- Finder

### Screen
- Single monitor
- MacBook + external monitor
- Full Screen app
- Space 전환
- 모니터 연결/해제
- 해상도 변경

### Auto Reset
- Korean 상태에서 앱 전환 → ABC
- English 상태에서 앱 전환 → 그대로 ABC
- 옵션 OFF → 상태 변경하지 않음
- ESC → ABC
- ESC reset 옵션 OFF → 상태 변경하지 않음

### Performance
- 30분 idle CPU
- 장시간 메모리 증가 여부
- 빠른 앱 전환 시 CPU spike
- 빠른 한/영 전환 시 UI 지연 여부

---

## 16. 성공 기준
KeyHue MVP가 성공했다고 판단하는 기준:

1. 한/영 전환 결과가 즉시 하단 라인에 반영된다.
2. 전환 실패 시 잘못된 상태를 표시하지 않는다.
3. Caps Lock을 즉시 인지할 수 있다.
4. 대부분의 앱과 Full Screen에서 표시된다.
5. 앱 전환 시 ABC reset 옵션이 안정적으로 동작한다.
6. KeyHue 때문에 마우스/키보드 조작이 방해받지 않는다.
7. Idle CPU 사용량이 사실상 0%에 가깝다.
8. 사용자가 입력한 실제 텍스트를 읽거나 저장하지 않는다.

---

## 17. 제품 방향
KeyHue의 핵심은 단순한 Input Indicator가 아니다.

```text
현재 상태를 보이게 한다
        +
원하지 않는 입력 상태를 자동으로 정상화한다
```

즉,

> **Visualize → Verify → Reset**

이라는 흐름을 가진다.

첫 버전에서는 기능을 늘리는 것보다 **항상 켜놓아도 존재감이 없을 정도로 가볍고, 입력 실수를 확실히 줄여주는 것**을 가장 중요한 품질 기준으로 삼는다.
