# 0083. 로그에는 예외 단어의 개수만 남기고, 입력기는 KeyHue의 답을 끝까지 기다린다

상태: Accepted (구현·자동 검증, 실제 Ghostty 재검사 남음)

날짜: 2026-10-09

관련: [0036](0036-diagnostic-log.md), [0065](0065-correct-all-apps-with-feedback.md), [0073](0073-utility-posts-terminal-keys-for-the-input-method.md), [0077](0077-apply-a-new-permission-without-restart.md)

## 배경

릴리즈 전 검토에서 두 문제가 나왔다.

- **로그에 단어가 남음:** 설정 로그(`SettingsLogDescription`)는 모든 설정을 값 그대로 적는다. 고치지 않을 단어(`correctionIgnoredWords`, ADR 0065)가 생기면서 사용자가 고른 단어가 설정을 바꿀 때와 실행할 때마다 `KeyHue.log`와 통합 로그에 남았다. "입력한 글자는 남기지 않는다"(ADR 0036)와 어긋나고, 로그를 이슈에 첨부하면 공개된다.
- **Backspace가 두 번 나갈 수 있음:**
  - 입력기는 KeyHue의 답을 0.5초(`TerminalKeyPost.timeout`)만 기다렸다.
  - KeyHue는 실행 뒤에 허용된 권한이면 작업 프로세스로 키를 보내고(ADR 0077), 최대 1초를 기다린다.
  - 0.5초 안에 답이 없으면 입력기는 KeyHue가 없는 것으로 보고, 권한이 있으면 Backspace를 직접 보냈다. 작업 프로세스의 Backspace까지 도착하면 단어 앞 명령까지 지워진다.
  - 입력기에 권한이 없으면 실패로 보고 기다리던 키를 버렸다. 이 경우 작업 프로세스의 Backspace가 단어만 지우고 고친 글자는 들어가지 않는다.

## 결정

- **로그:** `correctionIgnoredWords`는 `count=N`으로만 적는다(`KeyHueSettings.countOnlyNames`). 같은 개수의 다른 단어로 바뀌어도 바뀐 것으로 적는다.
- **답 기다리기:**
  - 요청을 보내는 데는 0.5초, 답을 기다리는 데는 1.5초(`replyTimeout`)를 쓴다.
  - KeyHue가 걸릴 수 있는 시간(`workerTimeout` 1초 + 멈추는 시간 `workerStopGrace` 0.2초)보다 길다.
- **결과 구분 (`TerminalKeyPost.clientStep`):**
  - **보내지 못함(`unreachable`):** KeyHue가 실행 중이 아니다. 이때만 ADR 0073 이전처럼 입력기가 직접 보낸다.
  - **보냈지만 답 없음(`unanswered`):** KeyHue가 보내는 중일 수 있다. 직접 보내지 않고, 보낸 것처럼 키를 기다린다. 기존 도착 확인이 결과를 정한다. 다 오면 고친 글자를 넣고, 일부만 와도 넣는다. 하나도 오지 않으면 아무것도 하지 않는다.

## 결과

- 로그를 첨부해도 사용자가 고른 단어는 드러나지 않는다.
- 터미널 고침에서 Backspace가 두 번 나가지 않는다.
- KeyHue가 멈춰 있으면 고칠 때 입력기가 최대 1.5초(이전 0.5초) 기다린다. 정상일 때 답은 수 ms 안에 온다.

## 검증

- `SettingsLogDescriptionTests`: 단어 대신 개수, 같은 개수의 교체도 변경으로 기록, `countOnlyNames`가 실제 설정 이름인지.
- `TerminalKeyPostTests`: 답 없음은 다시 보내지 않음, KeyHue가 없을 때만 직접 보냄, 대기 시간 순서.
- 남음: KeyHue의 손쉬운 사용 권한을 초기화하고 실행 → 터미널 ⌥↩ → 허용 → 다시 ⌥↩로 Backspace가 한 번만 나가는지 Ghostty에서 확인한다(ADR 0077 실제 확인과 같은 절차).
