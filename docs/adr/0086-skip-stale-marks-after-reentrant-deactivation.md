# 0086. 편집 도중 세션이 끝나면 이미 확정된 조합을 다시 표시하지 않는다

- 상태: Accepted (구현·단위 테스트. Fork 실제 재현은 아직 못 함)
- 날짜: 2026-10-11
- 관련: [0048](0048-current-syllable-composition-and-input-mode-icons.md), [0064](0064-correction-modes-off-manual-automatic.md), [0036](0036-diagnostic-log.md), [0082](0082-key-acknowledgement-system-abc-and-suspect-log.md)

## 맥락

사용자 보고: 자동 고침 모드에서 2026-10-10 13:17–13:18에 글자가 꼬였다. 자동으로 고치다가 꼬인 것 같다. 사용자는 13:18:09에 단어 고침을 자동에서 수동으로 바꿨다.

로그에서 확인한 것:

- **자동 고침은 실행되지 않았다.** 이 구간에는 `automatic correction decided`도, `correction probe automatic …`도 없다. 10일 하루 동안 자동 고침 기록은 09:35의 건너뜀 한 건뿐이다.
- 13:17:41–13:17:57에 Fork(`com.DanPristupov.Fork`)에서 한글을 칠 때 입력기 세션이 거의 키마다 비활성화됐다가 다시 활성화됐다. 키 입력과 함께 세션이 다시 활성화된 경우가 1분 동안 18번 있었다. 이틀치 로그에서 이런 일은 이 1분에만 있었다. 같은 Fork 입력창(같은 세션)에서 12:35에 5분 동안 칠 때는 한 번도 없었다.
- 직전 상황: 13:08–13:17:26 화면 잠금. 잠금을 풀자 ABC가 선택됐다. 13:17:41에 한/영을 누르자 ABC → Latin → Hangul 경로(0082)를 탔고, 그 순간 macOS 커서 입력 표시기(`TUINSCursorUIController`)가 Fork에 새로 만들어졌다. Fork가 왜 이때만 그렇게 동작했는지는 확인하지 못했다.
- macOS 통합 로그(`log show`, InputMethodKit 추적)에 키 하나의 처리 순서가 남아 있었다.

```
13:17:41.854  Inserting text        ← 키 처리: 완성된 앞 음절 확정 (예: "가")
13:17:41.856  Deactivate Server     ← Fork가 insertText 안에서 입력기를 비활성화
13:17:41.856  Inserting text        ← deactivate → commitComposition이 조합 중인 "나"를 확정
13:17:41.858  Setting marked text   ← 처음 키 처리가 이어서 "나"를 다시 조합으로 표시
13:17:41.897  Activate Server
```

원인은 입력기에 있다. `ProbeSession.letter`는 새 음절이 생기면 `[.commit("가"), .mark("나")]`를 만든다. 컨트롤러는 이 동작을 차례로 적용한다. 그런데 첫 `insertText` 안에서 클라이언트가 `deactivateServer`를 부르면, 그 안의 `commitComposition`이 세션의 조합 `나`를 이미 확정하고 세션을 비운다. 바깥 반복문은 이를 모르고 남은 `.mark("나")`를 그대로 적용한다. 그래서 앱에는 `가나`에 더해 세션이 모르는 조합 글자 `나`가 남는다. 다음 경계 키에서는 이 글자가 앱에서 확정되어 `가나나`가 되고, 다음 자모는 이 글자를 대체해 앞 음절과 합쳐지지 않는다. 이 경로는 자동·수동·끔 모두 같다. 자동 고침과는 관계없다.

## 결정

- 동작 목록을 적용하는 도중 세션의 조합이 끝났으면(클라이언트가 편집 안에서 비활성화·확정·취소를 불렀으면) **남은 `.mark`는 적용하지 않는다.** 그 조합은 이미 확정됐다.
- 남은 `.commit`은 그대로 적용한다. 그 글자는 다른 곳에 없다. 예를 들어 영문 모드의 `[앞 조합 확정, 친 글자 확정]`은 친 글자를 잃지 않는다. 비활성화 뒤 `insertText`는 `commitComposition`도 하는 일이라, 이 시점에서도 클라이언트가 받는다(위 로그).
- 판단 기준은 `ProbeSession.endedCompositions`이다. 이 값은 조합이 확정되거나(`finish`) 앱 상태에 맞춰 비워질 때(`reconcile`) 늘어난다. 새 음절로 넘어가는 것은 조합이 이어지는 것이므로 세지 않는다. 컨트롤러는 적용을 시작할 때 값을 기억하고, 동작마다 바뀌었는지 본다(`ActionDelivery.deliver`). 세대 번호(`contextGeneration`)는 쓰지 않는다. 비활성화 없이 다시 활성화만 되어도 바뀌는데, 이때 표시를 건너뛰면 조합이 남은 채 표시만 사라지고 다음 키의 `reconcile`이 그 조합을 버린다.
- 건너뛰면 입력기 로그에 `composition ended during delivery; stale mark skipped`와 클라이언트 번들 ID를 남긴다. 글자는 남기지 않는다.

## 영향

- 클라이언트가 조합 도중 세션을 끝내면 그 자리에서 음절이 끊긴다(`가나` 뒤의 `ㄴ`은 `난`이 되지 않는다). 시스템 입력기도 비활성화 때 조합을 확정하므로 같다. 글자가 두 번 나오거나 세션이 모르는 조합이 남는 일은 없어진다.
- Fork가 왜 편집마다 입력기를 비활성화했는지는 이 결정으로 바뀌지 않는다. 다시 보이면 통합 로그의 `Deactivate Server` 순서와 새 로그 줄로 확인한다.
- 자동 고침(0064)은 이 경로를 쓰지 않는다. 고침 편집은 `CorrectionProbe`가 클라이언트 상태를 다시 확인한다.

## 검증

- `ActionDeliveryTests`: `rks` 다음 `k`의 앞 음절 확정 안에서 비활성화(세션 `finish` 후 적용)를 흉내 내면 앱은 `가나`, 조합 없음, 세션 조합 없음. 다음 `s`는 새 조합 `ㄴ`이다. 재진입이 없으면 모든 동작이 적용되고 Backspace의 빈 조합(`.mark("")`)도 그대로 간다. 끝난 뒤의 `.commit`은 적용되고 `.mark`만 건너뛴다. `endedCompositions`는 확정과 `reconcile`에서만 늘고 음절이 넘어갈 때는 늘지 않는다.
- 기존 입력기 코어 테스트 전체 통과.
- 남은 확인: Fork 실제 재현. 같은 조건(잠금 해제 직후 ABC → 한/영 → Fork 입력창)에서 다시 일어나면 이 ADR에 결과를 덧붙인다.
