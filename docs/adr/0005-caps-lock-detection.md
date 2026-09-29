# 0005. Caps Lock은 flagsChanged monitor + 시점 보정으로 감지한다

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
Caps Lock은 Input Source와 별개 상태이며 우선순위가 가장 높다(Caps ON → CAPS 표시, OFF → Source 색 복원). 기본 기능이므로 추가 권한 없이 동작해야 한다.

## 결정
- `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` + local monitor(메뉴가 열려 KeyHue가 이벤트를 받을 때)로 변경을 받는다.
- 이벤트를 놓칠 수 있는 시점(앱 전환, Space 전환, 깨어남, Source 변경)에는 `CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)`로 HID 상태를 다시 읽는다.
- 우선순위는 `InputState.resolve(sourceKind:isCapsLockOn:)` 한 곳에서만 결정한다.
- 주기적 polling은 하지 않는다.

## 결과
- 권한 없이 동작하는 경로만 사용한다.
- 알려진 제약: macOS가 "Caps Lock 키로 ABC 입력 소스 전환"으로 설정된 경우 짧게 누르면 Caps가 아니라 Source가 바뀐다. 이때는 Source 변경으로 정상 표시된다.
- global flagsChanged 이벤트가 특정 보안 입력 상황(비밀번호 필드의 Secure Input 등)에서 전달되지 않으면, 다음 보정 시점까지 표시가 늦을 수 있다. 실제 기기에서 추가 검증이 필요하다.
