# 0075. 손쉬운 사용 권한은 그 권한을 쓰는 기능이 켜졌을 때만 확인한다

상태: Accepted (구현·자동 검증, 이 Mac에서 처음 설치 시나리오로 확인)

날짜: 2026-10-06

관련: [0021](0021-keep-permissions-across-builds.md), [0073](0073-utility-posts-terminal-keys-for-the-input-method.md), [0074](0074-uninstall-script-resets-to-first-install.md)

## 배경

ADR 0074의 제거 스크립트로 처음 설치 상태를 만든 뒤 시나리오를 검증했다(macOS 26.6.2, KeyHue 0.2.5·빌드 101). **입력 모니터링을 허용할 수 없었다.**

- 증상:
  - 입력기 설치와 "다시 허용"에서 KeyHue가 요청해도 시스템 설정 › 입력 모니터링 목록에 KeyHue가 나타나지 않았다.
  - `inputMonitoring=false`가 계속됐고, ESC 전환도 동작하지 않았다.
- `tccd` 로그(13:35:24): KeyHue의 입력 모니터링 요청(`kTCCServiceListenEvent`, `preflight=no`)이 **묻지 않고 거부**됐다(`authValue=0`, `authReason=4` System Set). 판단 근거는 다음 줄이었다.

  ```
  Evaluated composed authorization from kTCCServicePostEvent to parent service kTCCServiceAccessibility: Auth:Denied (System Set)
  ```

- 시스템 TCC 데이터베이스에는 실행 직후(13:31:47) 만들어진 **손쉬운 사용 "거부(System Set)"** 행이 있었다. 이 행은 KeyHue가 손쉬운 사용 권한을 확인하자(`AXIsProcessTrusted()`, 앞 앱 대상 AX 호출) macOS의 `universalAccessAuthWarn`이 쓴 것이다(`TCCAccessSetInternal`).
- 실험으로 원인을 좁혔다(매번 손쉬운 사용 초기화 → 실행 → 데이터베이스 확인):
  - 실행 단계마다 로그를 남겨 시각을 맞췄다.
  - Caps Lock의 전역 이벤트 감시를 끈 빌드에서도 행이 생겼다. 원인이 아니다.
  - 생성자의 AX 응답 대기 설정(`AXUIElementSetMessagingTimeout`)을 미룬 뒤에도, 실행 로그와 1초 뒤 권한 점검의 `AXIsProcessTrusted()` 직후 행이 생겼다.
- **정리:** macOS 26에서는 손쉬운 사용 확인만으로도 앱이 손쉬운 사용 목록에 "거부"로 들어간다. 그 행이 있으면 입력 모니터링 요청이 이벤트 전송 → 손쉬운 사용으로 합성 평가돼 묻지 않고 거부된다.
- 기본 설정에는 손쉬운 사용을 쓰는 기능(텍스트 필드 이탈, 창 전환)이 없다. 그런데도 실행할 때마다 확인하고 있었다.

## 결정

- **확인 조건:** 손쉬운 사용 권한 확인(`AccessibilityFocusMonitor.isTrusted`)과 AX 호출은 그 권한을 쓰는 기능이 켜져 있을 때만 한다(`KeyHueSettings.usesAccessibility`: 텍스트 필드 이탈 또는 창 전환).
  - 실행 로그는 쓰지 않으면 `accessibility=unused`로 남긴다.
  - 실행 1초 뒤 권한 점검(`PermissionFlow.warnIfMissing`)도 그 기능이 켜져 있을 때만 확인한다.
  - AX 감시는 붙을 용도가 있을 때만 권한을 확인하고, 응답 대기 설정은 처음 붙을 때 한다.
- **터미널 고침의 키 보내기(ADR 0073):** 유틸리티에 이벤트 전송 권한이 없으면 처음 요청에서 한 번 macOS에 요청한다(`CGRequestPostEventAccess`). 미리 확인하지 않으므로 그전에는 손쉬운 사용 목록에 KeyHue가 없다.
- **제거 스크립트(ADR 0074):** 두 번들의 권한을 서비스별이 아니라 `tccutil reset All`로 초기화한다. macOS가 따로 만든 항목(전체 디스크 접근 거부 등)까지 지운다.

## 결과

- 처음 설치에서 입력 모니터링이 필요한 기능(ESC, 입력기 두 모드 유지, 한/영 알림)을 켜면 macOS가 묻고, 목록에 KeyHue가 나타난다.
- **한계:** 사용자가 손쉬운 사용 기능을 먼저 켜고 허용하지 않은 상태에서 입력 모니터링을 요청하면, 같은 합성 평가로 다시 묻지 않고 거부될 수 있다. 이때는 시스템 설정의 입력 모니터링에서 +로 KeyHue를 추가해야 한다. 손쉬운 사용을 허용하면 이벤트 전송 → 손쉬운 사용 합성으로 입력 모니터링도 허용되는 것으로 보이지만, 실제로 확인하지는 않았다.
- 손쉬운 사용 기능을 쓰지 않는 사용자의 손쉬운 사용 목록에는 KeyHue가 나타나지 않는다.

## 검증

- `scripts/verify.sh` 통과.
- 실제 확인(2026-10-06 13:48~13:49):
  - 고친 빌드를 제거 스크립트로 지우고 다시 설치했다. 실행 뒤 손쉬운 사용 행이 생기지 않았다(`accessibility=unused`).
  - ESC를 켜자 macOS 요청이 떴고, 목록에 KeyHue가 나타나 허용했다(`kTCCServiceListenEvent` auth 2).
  - 다시 실행하자 `inputMonitoring=true`, 키보드 감시가 시작됐다.
