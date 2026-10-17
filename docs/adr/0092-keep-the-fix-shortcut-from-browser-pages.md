# 0092. 브라우저에서도 고침 단축키가 페이지에 가지 않게 한다

- 상태: Accepted (구현·단위 테스트·Chrome Google 검색창 실제 확인)
- 날짜: 2026-10-17
- 관련: [0066](0066-ghostty-commit-after-tab-and-navigation-keys.md), [0068](0068-fix-words-with-a-shortcut.md)

## 맥락

사용자 보고: Chrome의 Google 검색창에서 고침 단축키(⌥↩)를 누르면 검색이 실행된다.

2026-10-17 09:33:24, :30, :33, :52에 `shortcut correction result=corrected`가 남고, 약 150ms 뒤마다 Chrome이 입력기 세션을 닫았다(페이지 이동). 입력기는 단축키를 처리했다고 답하지만(0068), 단어를 바꾸는 일은 키가 끝난 뒤의 다음 턴에 한다(`ShortcutCorrector.interval`). Chrome은 키를 처리하는 동안 입력기가 글자를 넣거나 조합을 남기지 않으면 그 키를 페이지에 보낸다. 페이지는 ⌥↩를 Return으로 받아 검색을 실행했다. Ghostty의 같은 문제(0068: ⌥↩가 셸에 `ESC Return`으로 감)와 같은 모양이다.

## 결정

- Chromium 계열 브라우저(Chrome·Chromium·Edge·Brave·Vivaldi·Opera·Arc·Whale)에서는 단축키를 처리하는 동안 폭 없는 자리표시(U+200B)를 조합 중으로 두고, 키가 끝나면 지운다(`DetachedCommit.consume`). 조합이 남은 키는 Chrome이 페이지에 처리 중 키로 보낸다.
- Ghostty와 달리, 확정할 글자가 있어도 그 뒤에 자리표시를 둔다. 확정하면 조합이 끝나서 키가 그대로 페이지에 간다.
- 자리표시는 고침이 단어를 읽기 전(같은 main queue의 앞 작업)에 지워져 단어에 섞이지 않는다.
- Tab·방향키의 확정 미루기(0066)는 브라우저에 적용하지 않는다.

## 하지 않은 것

- Safari·Electron 앱은 확인하지 않아 넣지 않았다.

## 검증

- `ConsumedKeyTests`: 브라우저는 확정할 글자가 없을 때와 있을 때 모두 자리표시를 두고 지운다. 브라우저는 Tab 확정을 미루지 않는다. TextEdit·Terminal·iTerm2·Safari는 그대로다.
- 실제 기기: 2026-10-17 Chrome의 Google 검색창에서 ⌥↩가 검색을 실행하지 않고 단어만 고쳤다(사용자 확인).
