# 0004. Input Source는 TIS + distributed notification으로 감지한다

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
키 입력(한/영 키, Caps Lock 전환 설정, Ctrl+Space 등)으로 상태를 추측하면 전환 실패를 잡지 못한다. 명세는 "실제로 선택된 Input Source"를 읽고, 실패 시 색이 바뀌지 않아야 한다고 요구한다. 고주기 polling은 금지다.

## 결정
- 조회: `TISCopyCurrentKeyboardInputSource()` → `kTISPropertyInputSourceID`, `LocalizedName`, `InputSourceLanguages`, `IsASCIICapable`만 읽는다.
- 감지: `DistributedNotificationCenter`에서 `kTISNotifySelectedKeyboardInputSourceChanged`(+ `kTISNotifyEnabledKeyboardInputSourcesChanged`)를 구독하고, 알림을 받으면 **항상 TIS에서 다시 읽는다**(알림 payload를 믿지 않는다).
- 보정: 앱 전환·깨어남 시점에도 한 번 다시 읽어 놓친 알림을 보정한다(이벤트 기반, 타이머 없음).
- 분류(`InputSourceClassifier`):
  1. 주 언어가 `ko`(`ko-*`) → Korean
  2. ASCII 입력 가능 또는 주 언어가 `en` → English (ABC, U.S., Dvorak, 독일어 등 라틴 배열 포함)
  3. 그 외(일본어/중국어 IME 등) → Other → 화면에는 `unknown`(회색)
- ID 문자열 패턴(`Korean` 포함 여부 등)에 의존하지 않고 언어 속성으로 판정해 구름(Gureum) 등 서드파티 IME도 동작하게 한다.

## 결과
- 실측(ABC ↔ 2-Set Korean 스크립트 전환)에서 알림 → 상태 반영이 즉시 이뤄지고 idle CPU 0.0%를 확인했다.
- 한 입력기 안에서 한/영 모드를 전환하는 IME는 "모드"가 별도 Input Source로 노출될 때만 구분된다(Apple 한국어 입력기와 구름은 해당).
