# 0091. macOS가 ⌘Space 전환을 바로 되돌리면 누른 결과로 다시 고른다

- 상태: Accepted (구현·단위 테스트, 실제 기기 확인은 남음)
- 날짜: 2026-10-17
- 관련: [0062](0062-repair-input-method-session-with-previous-source-shortcut.md), [0071](0071-route-through-the-leaving-mode-and-wait-for-modifier-release.md), [0082](0082-key-acknowledgement-system-abc-and-suspect-log.md)

## 맥락

사용자 보고: 2026-10-17 09:08–09:09, 09:23–09:24 ⌘Space 한영 전환이 1분 사이에 여러 번 안 됐다.

Chrome에서 09:08:38, :42, :44, 09:09:03에, Ghostty에서 09:23:32, :40, :56, :58, 09:24:02에 같은 모양이 나왔다.

```
09:08:38.686 kCGSEventFlagsChanged (⌘ 누름; Space는 시스템 단축키라 앱·tap에 오지 않음)
09:08:38.928 kCGSEventFlagsChanged (⌘ 뗌 — macOS는 이때 전환을 확정한다)
09:08:38.931 TextInputSwitcher가 기본 ASCII 자판을 읽음 (두 번: .931, .935)
09:08:38.948 KeyHue: source=Hangul
09:08:38.971 KeyHue: source=Latin       ← 23ms 뒤 되돌아감
             TextInputSwitcher 소스 표시 말풍선 두 번
```

- 두 번의 전환 모두 macOS(TextInputSwitcher)가 했다. 그 사이 KeyHue의 `source selection` 로그(자동 전환·라우팅·세션 복구)는 없고, 입력기도 모드를 고르지 않았다.
- ⌘를 뗄 때 TextInputSwitcher가 두 번 반응하면(.931·.935) 되돌아갔다. 한 번만 반응한 누름은 정상이었다. 입력기를 다시 설치·재시작한 뒤에도 같았다.
- 같은 모양(KeyHue 두 모드 사이를 0.1초 안에 왕복)은 10-09부터 로그에 있다. Chrome 119번 중 18번, Ghostty 284번 중 13번.
- 처음에는 flagsChanged를 Caps Lock으로 잘못 읽어 Caps Lock 뒤에만 고쳤다. 사용자는 Caps Lock을 쓰지 않았고(Caps Lock은 대문자 잠금만 켰다, 09:25:45), 09:24:02에 그대로 재현됐다. 측정 tap으로 ⌘Space의 Space keyDown은 session tap에 오지 않고 ⌘의 flagsChanged만 온다는 것을 확인했다.

macOS 안의 원인은 KeyHue가 바꿀 수 없다.

## 결정

1. **전환 직후 macOS가 되돌리면 누른 결과를 다시 고른다** (`DoubleSwitchDetector`). 조건을 모두 만족할 때만이다.
   - 두 변경 모두 KeyHue 두 모드 사이다(ABC·시스템 두벌식은 0071·0082가 다룬다).
   - 두 번째 변경이 첫 변경을 정확히 되돌린다(X → Y → X).
   - 0.1초 안이다(실측 17–46ms). 사람이 그 안에 두 번 전환할 수 없다.
   - 0.5초 안에 수식 키(⌘·⌃·⌥·⇧·Caps Lock·Fn)가 바뀌었다. ⌘Space·Caps Lock 전환은 수식 키를 뗄 때 일어난다(약 20ms 뒤).
   - 그 사이 키·클릭·KeyHue 자신의 선택(자동 전환·라우팅·세션 복구)이 없다. KeyHue가 고르면 그 누름은 잊는다. 늦게 오는 자기 선택 알림을 되돌림으로 보지 않는다. 세션 복구의 ⌘Space 두 번(0062)은 표시가 붙은 키라 tap이 무시하고, 복구 중 알림도 보지 않는다.
2. **키 감시가 수식 키 변경을 본다.** listen-only tap에 `flagsChanged`를 더하고 키 코드가 수식 키인지만 본다. 문자는 읽지 않는다.
3. **로그**: `[Suspect] reason=switched-back app=… undone=Latin restored=Hangul: ok`.

## 하지 않은 것

- 되돌린 뒤 다시 되돌아가도 한 번만 고른다(누름 하나에 한 번).
- 입력기의 Info.plist·`recognizedEvents`로 macOS의 두 번째 반응을 막을 수 있는지는 실험하지 않았다.

## 검증

- `DoubleSwitchDetectorTests`: 09:08:38·09:09:03(Chrome, 두 방향)·09:24:02(Ghostty) 순서를 되돌리고, 그 선택의 알림은 다시 되돌리지 않음. 한 번씩의 정상 전환, 수식 키 없는 왕복, 0.1초보다 늦은 왕복, 오래된 수식 키 변경, 키·클릭·자기 선택이 끼어든 경우, 자기 선택 뒤의 알림, 우회 소스, 기준선 재설정, 같은 소스 알림 반복.
- 실제 기기: ⌘Space 전환에서 `switched-back` 로그와 최종 소스를 확인해야 한다.
