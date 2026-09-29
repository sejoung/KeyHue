# 0008. ESC는 listen-only CGEventTap(Input Monitoring)으로 감지한다

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
다른 앱이 앞에 있을 때 ESC를 감지하려면 전역 키 이벤트 관찰이 필요하고, 이는 TCC 권한을 요구한다. 명세는 권한이 필요한 기능을 핵심 표시 기능과 분리하고, 입력 내용을 절대 기록하지 않도록 요구한다.

## 결정
- `CGEvent.tapCreate(.cgSessionEventTap, .tailAppendEventTap, **.listenOnly**, mask: keyDown)`를 사용한다.
  - 필요한 권한은 **Input Monitoring**(`CGPreflightListenEventAccess`/`CGRequestListenEventAccess`)이다. Accessibility(다른 앱 제어 가능)보다 범위가 좁다.
  - listen-only이므로 이벤트를 수정/차단하지 않는다. 입력 지연이나 키 누락을 만들 수 없다.
  - 콜백에서는 `keyboardEventKeycode`와 `keyboardEventAutorepeat`만 읽는다. 문자열(`keyboardGetUnicodeString`)은 호출하지 않으며 어떤 키도 저장하지 않는다.
  - `tapDisabledByTimeout/UserInput`을 받으면 즉시 다시 켠다.
- 권한 흐름:
  1. 앱 시작 시에는 아무것도 묻지 않는다.
  2. 사용자가 "Reset to ABC on ESC"를 켜면 먼저 KeyHue alert로 이유를 설명하고, 동의 시 시스템 권한 요청 → 이미 거부된 경우 System Settings의 Input Monitoring 화면을 연다.
  3. 권한이 없으면 메뉴 항목이 mixed(–) 상태로 표시되고 "Grant Input Monitoring Access…" 항목이 나타난다(graceful fallback). 나머지 기능은 영향이 없다.
  4. 메뉴를 열 때/앱 전환 때 tap 생성을 재시도하므로 권한을 허용하면 자동으로 활성화된다(일부 macOS 버전은 재실행 필요).
- ESC 처리 후 전환은 다음 run loop에서 실행해, 앱이 ESC를 먼저 처리하게 한다.

## 결과
- 권한 부여/거부 흐름과 실제 ESC 전환은 권한이 필요한 수동 테스트로 확인해야 한다(자동화 환경에서 미검증).
- ad-hoc 서명 빌드는 재빌드마다 권한을 다시 허용해야 할 수 있다(ADR 0002).

## 검토한 대안
- **`NSEvent.addGlobalMonitorForEvents(.keyDown)`**: Accessibility 권한이 필요하다(범위가 더 넓다).
- **IOHIDManager**: Input Monitoring이 필요하고 코드가 더 복잡하며 이점이 없다.
