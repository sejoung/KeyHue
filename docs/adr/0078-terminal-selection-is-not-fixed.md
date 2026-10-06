# 0078. 터미널에서 선택한 글자는 고치지 않고, 왜 안 되는지 알린다

상태: Accepted (구현·자동 검증. Ghostty 실제 검사 남음)

날짜: 2026-10-06

관련: [0067](0067-bidirectional-correction-and-terminals.md), [0068](0068-fix-words-with-a-shortcut.md), [0071](0071-route-through-the-leaving-mode-and-wait-for-modifier-release.md)

## 배경

사용자가 셸에서 `asd`를 Shift+←로 선택하고 ⌥↩를 눌렀다. "고칠 단어가 없습니다"가 떴다. 선택했으니 바뀌어야 하지 않느냐는 질문이었다. 이 Mac에는 zsh-shift-select 플러그인을 쓰고 있다.

- **글자를 알려 주는 앱:** 선택한 글자를 앱에서 읽어 고친다(ADR 0068).
- **터미널:** 글자도 선택도 알려 주지 않는다. 입력기가 받은 키로 커서 앞 단어를 알고(`TypedWord`), Backspace 키로 지운 뒤 넣는다(ADR 0067).
- **셸의 선택:** Shift+화살표 선택은 셸(zsh-shift-select)이나 프로그램 안의 상태다. 입력기에는 커서 이동으로만 보이므로 기억한 단어를 비운다(`cleared=boundary key`).
- **억지로 고치면 위험하다:**
  - 선택이 있는 동안 zsh-shift-select는 첫 Backspace로 선택 전체를 지운다. "Backspace N개 → 넣기"는 선택 뒤의 N-1개로 선택 앞 글자까지 지운다.
  - 선택 위의 Backspace 동작은 셸·플러그인·프로그램(Claude Code 등)마다 다르다. 하나를 가정할 수 없다.

## 결정

- 터미널에서는 선택 영역을 고치지 않는다. 지금처럼 아무것도 지우지 않고, 단축키도 프로그램에 보내지 않는다.
- **안내:** 단어가 비어 있는 이유가 Shift+화살표(키 코드 123~126, Shift만)이면 실패 이유를 `terminalSelection`으로 알린다. 안내는 "선택한 글자는 여기서 고칠 수 없습니다 — 터미널은 선택한 글자를 알려 주지 않습니다. 선택을 풀고 단어 바로 뒤에서 단축키를 누르세요."다.
- **기록:** "고칠 단어 없음"처럼 사용자의 상황이라 "고치지 못한 앱"에는 기록하지 않는다.

## 결과

- 사용자는 왜 안 되는지와 어떻게 하면 되는지 바로 안다.
- 터미널에서 선택 고침은 지원하지 않는다. 셸이 선택을 알려 줄 방법이 생기거나 프로그램별 동작을 확정할 수 있을 때 다시 정한다.

## 검증과 한계

- `CorrectionFeedbackTests`: 터미널 선택은 보이되 기록하지 않음.
- `CorrectionFeedbackStoreTests`: 안내 문구.
- Ghostty 고침 검사: Latin 모드에서 `asd` 뒤 Shift+← 세 번, 그리고 ⌥↩.
  - 기대하는 바이트는 `asd` + Shift+← 두 번이다. 첫 번째는 조합 중 글자 확정에 쓰인다(ADR 0066). 지우기(`\x7f`)와 단축키 바이트가 없어야 한다.
  - 입력기 로그에 `reason=terminalSelection`이 있어야 한다.
  - 입력기를 업데이트한 뒤 실행한다.
