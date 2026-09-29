# KeyHue 제품 명세

> 이 문서는 KeyHue의 제품 명세(한국어)다. 사용 방법과 빌드는 [README](../README.md) / [README.ko](../README.ko.md), 설계 결정은 [ADR](adr/README.md)에 있다.

> macOS의 현재 입력 소스를 화면 가장자리 색으로 즉시 인지하고, 잘못된 언어로 입력하는 실수를 줄여주는 가볍고 빠른 네이티브 유틸리티.
> 한/영에서 출발했지만 **입력 소스마다 색을 지정**할 수 있어 일본어·중국어·러시아어 등 어떤 언어 조합에서도 동작한다.

## 1. 제품 목표
KeyHue는 macOS 기본 입력 소스 표시의 낮은 가독성을 보완한다. 사용자가 타이핑하기 전에 현재 입력 상태가 **어떤 입력 소스인지(한글, 영문, 일본어…), Caps Lock인지** 시선을 옮기지 않고 알 수 있게 한다.

추가로 앱 전환이나 ESC 입력 같은 상황에서 입력 소스를 기본 입력 소스(보통 ABC)로 되돌려, 다른 언어 상태가 남아 단축키나 명령 입력이 꼬이는 문제를 줄인다.

이 문제는 한국어 사용자만의 것이 아니다. 영어 외 언어를 함께 쓰는 사용자(일본어, 중국어, 러시아어, 그리스어, 아랍어·히브리어, 독일어/US 배열 혼용 등) 모두에게 있으므로, 상태를 "한/영"으로 고정하지 않고 **입력 소스별 색**으로 일반화한다([ADR 0013](adr/0013-per-input-source-colors.md)).

### 핵심 원칙
- **Lightweight**: 항상 실행해도 부담이 없어야 한다.
- **Native**: Swift + AppKit 중심.
- **Instant**: 입력 상태 변경이 체감상 즉시 반영.
- **Non-intrusive**: 마우스/키보드 입력을 방해하지 않는다.
- **Event-driven**: 고주기 polling을 피한다.
- **Privacy-first**: 입력한 문자 내용은 읽거나 저장하지 않는다.

---

## 2. MVP 기능

### 2.1 Input State Bar
현재 입력 상태에 따라 화면 가장자리에 컬러 라인을 표시한다. 기본값은 **화면 하단 3px**이다. 상단은 눈에 잘 띄지만 메뉴바를 가리는 느낌이 있어서 하단을 기본으로 둔다([ADR 0012](adr/0012-bar-position-opacity-thickness.md)).

색은 **시스템에 켜져 있는 입력 소스마다** 지정한다. 지정하지 않으면 아래 기본색을 쓴다.

| 입력 소스 | 기본 표시 |
|---|---|
| 영문 배열 (ABC, U.S., German, Dvorak…) | Blue |
| 한국어 | Green |
| 일본어 | Orange |
| 중국어 | Purple |
| 키릴 문자 (러시아어 등) | Teal |
| 그리스어 / 아랍어 계열 / 히브리어 | Indigo / Mint / Yellow |
| 그 밖의 언어 | 언어 코드로 고정 배정 (빨강 제외) |
| Caps Lock | Red (입력 소스 색보다 우선) |

```text
┌─────────────────────────────────────────────┐
│                                             │
│                현재 사용 중인 앱            │
│                                             │
└━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┘
               KeyHue State Bar
```

위치(Top / Bottom / Left / Right), 두께(1–16px), 불투명도(100 / 80 / 60 / 40%)는 설정에서 바꿀 수 있다.

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

> 2.4–2.5와 Phase 2의 "ABC"는 **기본 입력 소스**를 뜻한다. 기본은 자동(ABC → U.S. → 첫 영문 배열)이며 설정에서 German 등 다른 입력 소스로 바꿀 수 있다([ADR 0013](adr/0013-per-input-source-colors.md)).

### 2.4 앱 전환 시 ABC로 전환
옵션 기능. 사용자가 다른 앱으로 전환하면 입력 소스를 ABC로 변경한다.

```text
Slack (한글 입력 중)
        ↓ Cmd + Tab
VS Code
        ↓
ABC 자동 전환
        ↓
State Bar → English 색상
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
KeyHue는 메뉴바 아이콘(카멜레온)으로 동작하고, **Dock에도 앱 아이콘을 표시한다**(기본값). Dock 아이콘을 누르거나 앱을 다시 실행하면 설정 창이 열린다. 메뉴바에만 두고 싶은 사용자는 **Dock에 표시**를 끌 수 있고, 재시작 없이 바로 적용된다([ADR 0020](adr/0020-show-dock-icon-by-default.md)).

> 처음에는 `LSUIElement = YES`로 Dock에 표시하지 않았다. 실제로 써 보니 다시 실행해도 반응이 없고 앱을 찾기 어려워 기본값을 바꿨다.

메뉴 예시:

```text
KeyHue

Current Input: 2-Set Korean

✓ Show State Bar
✓ Switch to ABC on App Switch
✓ Switch to ABC on ESC
Default Input Source   >   Automatic (ABC) / 켜진 입력 소스들

Bar Position      Bottom
Bar Thickness     3px
Bar Opacity       100%
Colors             >   입력 소스별 · Caps Lock
Displays           >

Settings…         ⌘,
Launch at Login

Quit KeyHue
```

### State Bar 기본값
- 두께: 3px (1–16px)
- 위치: 화면 최하단 (Bottom / Top / Left / Right)
- 불투명도: 100% (100 / 80 / 60 / 40%)
- 애니메이션: 최소화
- 마우스 이벤트: 무시
- 그림자: 없음
- 텍스트: 없음

색상만으로 의미를 강제하지 않도록 향후 상태별 라인 패턴/두께 옵션도 검토한다. 입력 소스가 4–5개를 넘거나 색각 이상 사용자에게는 색만으로 구분하기 어렵기 때문이다.

### 설정 창
입력 소스가 많아지면 메뉴만으로는 부족하므로 SwiftUI 설정 창(⌘,)을 둔다([ADR 0015](adr/0015-settings-window-swiftui.md)).
- **일반**: 언어(시스템 기본값/English/한국어/日本語), State Bar 표시·위치·두께·불투명도, 디스플레이, 메뉴바 아이콘 색, HUD, 로그인 시 실행
- **입력 소스**: 켜진 입력 소스별 색 + Caps Lock 색, 기본 입력 소스
- **자동 전환**: 앱 전환/ESC/앱별 기억/텍스트 필드(실험적), 권한 상태

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
DB 없이 `UserDefaults`를 사용한다. **기본값과 다른 값만 저장**해서, 사용자가 건드리지 않은 설정은 이후 버전의 기본값 변경을 따라간다([ADR 0014](adr/0014-store-only-changed-settings.md)).

```swift
struct KeyHueSettings {
    var showStateBar: Bool
    var barHeight: Double                  // 1...16
    var barPosition: BarPosition           // bottom(기본) / top / left / right
    var barOpacity: Double                 // 0.2...1.0
    var sourceColors: [String: RGBAColor]  // Input Source ID → 사용자가 지정한 색
    var capsLockColor: RGBAColor
    var resetOnAppSwitch: Bool
    var resetOnEscape: Bool
    var defaultSourceID: String?           // nil = 자동(ABC → U.S. → 첫 영문 배열)
    // launchAtLogin은 저장하지 않고 SMAppService 상태를 읽는다
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

1. 한/영 전환 결과가 즉시 State Bar에 반영된다.
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

### 글로벌 출시
- 입력 소스별 색과 기본 입력 소스로 어떤 언어 조합에서도 동작한다(ADR 0013).
- UI는 영어·한국어·일본어로 시작하며, OS 언어와 별개로 앱 언어를 고를 수 있다(ADR 0016).
- 버전은 semver 태그로 관리하고(`scripts/release.sh`), 배포 바이너리는 Developer ID 서명 + notarization으로 만든다. Mac App Store는 샌드박스에서 입력 소스 전환·ESC 감지가 허용되는지 검증한 뒤 결정한다(ADR 0017).
- **알려진 한계**: 입력 소스를 바꾸지 않고 한 입력기 안에서만 모드를 바꾸는 경우(예: 일부 중국어 입력기의 Shift 중/영 전환)는 macOS가 알려주지 않아 감지할 수 없다.
