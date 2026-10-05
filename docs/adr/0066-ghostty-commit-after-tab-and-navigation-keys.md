# 0066. Ghostty에서는 조합 중 Tab·이동 키가 조합을 키와 따로 확정한다

- 상태: Accepted (구현·단위 테스트·Ghostty 실제 키 검사 완료)
- 날짜: 2026-10-04
- 관련: [0050](0050-synchronize-imk-mode-before-key-events.md), [0061](0061-external-selection-does-not-open-input-method-session.md)

## 배경

사용자 보고: Ghostty에서 조합 중에 Tab을 누르면 마지막 글자가 지워진다. 한글·영문 모드 모두 같다. Esc와 방향키는 괜찮다.

입력기는 조합에 쓰지 않는 키를 받으면 조합을 먼저 확정(`insertText`)하고 키는 앱에 넘긴다(ADR 0050 보완). TextEdit과 테스트 앱(`NSTextView`)에서는 Return·Tab·방향키 모두 마지막 글자가 남는다.

Ghostty 1.3.1은 입력기가 키 처리 중에 확정한 글자를 따로 보내지 않는다. 그 키 이벤트의 글자로 붙여 터미널 인코더에 넘긴다(`SurfaceView_AppKit.swift`의 `keyTextAccumulator`). 인코더는 키 하나에 글자 하나만 쓴다. 그래서 키에 따라 확정한 글자나 키 중 하나가 사라진다.

별도 Ghostty 창의 바이트 기록으로 확인했다(입력기 0.2.5, Ghostty 1.3.1, 한글 `ㅁㅠ` 조합 중):

| 키 | 기본 키 인코딩 | 
|---|---|
| Space | `뮤 ` |
| Tab | `\t` (**글자 사라짐**) |
| ←, ↓ | 방향키 순서열 (**글자 사라짐**) |
| Return, Esc | `뮤` (키 사라짐) |
| `.`, `1` | `뮤.`, `뮤1` |

kitty 키보드 프로토콜(Claude Code 등)에서는 Tab이 같은 방식으로 글자를 잃는다. 방향키·Esc는 글자를 남기는 쪽으로 인코딩된다(`key_encode.zig`). 사용자가 Claude Code에서 본 "Esc·방향키는 괜찮고 Tab만 지워진다"와 같다.

Ghostty의 알려진 문제다(ghostty-org/ghostty#11461). 시스템 2벌식 입력기도 같다. 고침(#12447, #12547)은 1.3.1 이후 개발 버전에 있고, Tab·Return·Esc까지 고치는 변경(#14272)은 병합되지 않았다.

## 결정

- Ghostty(`com.mitchellh.ghostty`)에서 조합 중에 Tab(Shift 포함)·방향키·Home·End·Page Up/Down·forward Delete가 오면 다음처럼 처리한다:
  - 조합을 끝내되 바로 넣지 않는다.
  - 키는 입력기가 받는다(`handled`).
  - 끝낸 글자는 그 키 처리가 끝난 뒤 메인 큐에서 따로 넣는다. Ghostty는 키 밖에서 받은 글자를 붙여넣기 경로로 보낸다. bracketed paste를 켠 프로그램에는 붙여넣기 표시가 붙는다.
  - 결과적으로 글자는 남고 그 키는 한 번 소비된다. Ghostty에서 Return·Esc가 이미 그렇게 동작하고, 사용자는 Esc의 이 동작을 "확정이 잘 된다"로 보았다.
- 조합이 없을 때의 Tab·방향키는 그대로 앱에 간다.
- ⌘·⌃·⌥ 단축키는 붙잡지 않는다. ⌃C 같은 키는 항상 앱에 가야 한다.
- 글자 키·Space·Return·Esc는 지금 경로를 유지한다. 이 키들은 Ghostty에서 글자를 잃지 않는다.
- 붙잡은 글자는 그 앱에 다른 것이 닿기 전에 먼저 넣는다:
  - 다음 키
  - 클릭
  - 모드 콜백
  - 활성화
  - 확정·취소 요청
  - 비활성화
- 넣기 전에 Tab·이동 키가 또 오면 그 키도 소비한다. 그 키에 붙이면 글자가 다시 사라지기 때문이다.
- 다른 앱은 지금처럼 "확정한 뒤 키를 넘김"을 유지한다. 같은 문제가 확인된 앱만 `DetachedCommit.clients`에 더한다.
- 붙잡은 글자의 처리 규칙은 순수 타입(`DetachedCommit`, `HeldCommit`)에 두고 단위 테스트로 고정한다.

## 결과

- Ghostty에서 조합 중 Tab·이동 키로 마지막 글자를 잃지 않는다. 대신 그 키를 한 번 더 눌러야 한다. 글자를 잃는 것보다 낫고, Return·Esc와 같은 동작이다.
- Ghostty가 확정 글자와 키를 함께 보내도록 고치면 이 우회는 필요 없다. Ghostty 새 버전에서 Tab·방향키가 글자와 함께 동작하면 대상에서 뺀다.
- `Tests/host/ghostty-input-method-e2e.sh`(opt-in)가 실제 Ghostty에서 확인한다. 사용자의 Ghostty 창은 읽지도 입력하지도 않는다. 별도로 띄운 Ghostty 프로세스가 받은 바이트만 기록하고, 기본 인코딩과 kitty+bracketed paste 두 방식을 검사한다.
- 2026-10-04 실제 검사(macOS 26.6.2, Ghostty 1.3.1): 두 방식 모두 한글 조합 중 Tab·←·↓, 영문 Tab·→에서 글자가 남았다. Space·`.`, 조합 없는 Tab, 소비된 Tab 뒤 다시 조합도 통과했다. Return·Esc는 `가`만 보냈다(Ghostty 동작, 이전과 같음).
- Ghostty는 띄운 직후 잠깐 자기 다른 클라이언트로 포커스를 옮길 수 있다. runner는 기록 창이 Space를 받은 뒤 검사를 시작한다.
