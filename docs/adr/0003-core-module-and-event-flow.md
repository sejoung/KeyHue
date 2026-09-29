# 0003. 순수 로직(KeyHueCore)과 OS 연동(KeyHue)을 분리하고 단방향 이벤트 흐름을 쓴다

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
명세는 "UI가 OS 이벤트를 직접 처리하지 않게 분리"를 요구한다. 또한 한/영 판정, Caps 우선순위, 자동 전환 조건처럼 틀리면 바로 사용자 실수로 이어지는 규칙은 실제 키보드/앱 없이 반복 검증할 수 있어야 한다.

## 결정
두 개의 타깃으로 나눈다.

| 타깃 | 역할 | 의존 |
|---|---|---|
| `KeyHueCore` (library) | `InputState`, `InputSourceClassifier`, `InputStateStore`, `ResetPolicy`, `ABCSourcePicker`, `TextInputRole`, `KeyHueSettings`/`SettingsStore`, `AppInputMemory`, `ScreenGeometry`, `RGBAColor` | Foundation, CoreGraphics |
| `KeyHue` (executable) | Monitors(TIS, flagsChanged, NSWorkspace, CGEventTap, AX), `InputSourceController`, `OverlayController`, `HUDController`, `StatusBarController`, `AppDelegate`(composition root) | AppKit, Carbon, ApplicationServices, ServiceManagement |

이벤트 흐름은 단방향이다.

```text
macOS Events ─▶ Monitors ─▶ InputStateStore ─▶ Overlay / HUD / StatusBar
                   │
                   └──▶ ResetPolicy(순수 판단) ─▶ InputSourceController(TIS 전환)
                                                     │
                                  (전환 결과는 다시 notification으로) ◀┘
```

- Monitor는 원시 값(Source 정보, Caps 여부, 활성 앱, 키 코드, focus role)만 보고한다.
- `InputStateStore`는 값이 실제로 바뀐 경우에만 observer를 호출해 중복 notification을 흡수한다.
- 자동 전환 판단은 `ResetPolicy`가 하고, 결과(`InputSourceAction`)만 앱 레이어가 실행한다. 전환 후 UI 갱신은 직접 하지 않고 **실제 Source 변경 notification을 통해서만** 반영한다 → "실제 Source가 바뀌지 않았다면 색도 바뀌지 않는다"는 원칙을 구조적으로 보장한다.
- 모든 런타임 객체는 `@MainActor`. C 콜백(CGEventTap, AXObserver)은 main run loop에 등록하고 `MainActor.assumeIsolated`로 진입한다.
- 테스트는 Swift Testing으로 `KeyHueCore`만 대상으로 한다.

## 결과
- 판정/정책 규칙을 53개 단위 테스트로 검증한다(`swift test`).
- OS 연동 코드는 얇게 유지되지만 단위 테스트가 없다. README §15의 수동 테스트 케이스로 보완한다.
