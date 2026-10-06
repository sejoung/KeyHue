# 0074. 처음 설치 상태로 되돌리는 제거 스크립트를 둔다

상태: Accepted (구현·스크립트 테스트 통과. 이 Mac에서의 실제 제거·재설치 시나리오는 아래 기록)

날짜: 2026-10-06

관련: [0051](0051-single-app-distribution-and-managed-input-method.md), [0055](0055-users-add-input-sources-manually.md), [0073](0073-utility-posts-terminal-keys-for-the-input-method.md)

## 배경

사용자 요청: 권한까지 모두 지워 이 Mac을 처음 상태로 만드는 스크립트가 있으면, 설치·권한·입력기 시나리오를 처음부터 검증할 수 있다.

KeyHue와 입력기가 남기는 것은 여러 곳에 흩어져 있다.

| 종류 | 위치 |
|---|---|
| 앱 | `/Applications/KeyHue.app`(또는 `~/Applications`) |
| 입력기 | `~/Library/Input Methods/KeyHueInputMethodSpike.app` |
| 입력 소스 등록 | `com.apple.inputsources` › `AppleEnabledThirdPartyInputSources` |
| 로그인 항목 | Background Task Management(`SMAppService.mainApp`) |
| 설정 | `io.github.sejoung.keyhue`, `io.github.sejoung.keyhue.inputmethod.spike`, 이전 개발 ID `ai.realdraw.KeyHue` |
| 파일 | `~/Library/Logs/KeyHue`, `~/Library/Application Support/KeyHue`(되돌린 고침 기록, 0073의 소켓), 캐시 |
| 권한 | 입력 모니터링(`ListenEvent`), 손쉬운 사용(`Accessibility`), 이벤트 전송(`PostEvent`), 앱·입력기 각각 |

앱의 **입력기 제거**는 사용자가 두 모드를 먼저 빼야 하고(ADR 0055), 앱과 설정·권한은 남긴다. 그래서 처음 상태 검증에는 맞지 않는다.

## 결정

- **`scripts/uninstall.sh`:** 위 모든 것을 지운다.
  - 기본 동작은 지울 것을 보여 주고 `y`를 받은 뒤 지우는 것이다. `--yes`는 묻지 않고, `--dry-run`은 보여 주기만 한다.
  - `--check`는 남은 것만 본다(없으면 0, 있으면 1).
  - 확인할 터미널이 없으면 `--yes` 없이는 지우지 않는다.
- **앱 프로세스 안에서 하는 단계:** 입력 소스 끄기와 로그인 항목 해제는 KeyHue 프로세스만 할 수 있다. 그래서 작업 모드 `--keyhue-prepare-uninstall`을 둔다(`UninstallPreparation`). 순서는 다음과 같다.
  1. KeyHue 모드가 선택돼 있으면 ABC(없으면 다른 ASCII 입력 소스)로 바꾼다.
  2. KeyHue 모드를 끄고, 마지막에 부모 항목을 끈다(`TISDisableInputSource`).
  3. 로그인 항목을 해제한다.
  - 단계마다 이름과 상태만 출력한다.
  - 앱이 없는데 입력 소스가 켜져 있으면 실패로 끝내고, 시스템 설정에서 빼라고 안내한다.
- **그다음 순서:** 앱과 입력기를 종료하고 → 설정·로그를 백업하고 → `tccutil reset All`로 두 번들 ID의 권한 항목을 모두 초기화하고(ADR 0075) → 파일과 설정을 지운다.
- **백업:** 기본으로 설정(`defaults export`)과 로그를 `~/KeyHue-uninstall-backup-<시각>`(0700)에 남긴다. 되돌릴 수 없는 삭제이기 때문이다. `--no-backup`이면 남기지 않는다.
- **지우지 않는 것:**
  - 이름이 KeyHue.app이어도 번들 ID가 다른 앱
  - 서명 키(`scripts/signing.sh`), 저장소의 `build/`·`.artifacts/`, 셸 설정
- **권한 초기화 시점:** 파일을 지우기 전에 한다. `tccutil`은 번들 ID를 LaunchServices로 찾으므로, 남아 있는 사본을 먼저 등록한다.
- **남은 입력 소스 정리:** 끄기에 성공했다고 답해도 macOS 26의 서드파티 모드 목록(`com.apple.inputsources`)에 남으면, 목록을 백업한 뒤 KeyHue 항목만 뺀다. 다른 입력기 항목은 그대로 둔다.
- **끝난 뒤 확인:** 같은 검사로 파일·설정·입력 소스·로그인 항목·프로세스가 남았는지 본다. 권한 목록은 일반 사용자가 읽을 수 없어 확인하지 않는다. 시스템 설정에서 보라고 안내한다.
- **ADR 0055와의 관계:** 이 스크립트는 사용자가 명시적으로 실행하는 개발·검증 도구다. 그래서 입력 소스를 스크립트가 끈다. 앱의 입력기 제거는 그대로 사용자가 모드를 빼게 한다.
- **처음 설치 시나리오:** `docs/TESTING.md`의 수동 체크리스트에 추가한다.

## 결과

- 한 명령으로 처음 설치 상태를 만들고, 같은 스크립트로 남은 것을 확인한다.
- 개인정보 보호 권한 초기화는 macOS가 처리한다. 항목이 없으면 `tccutil`이 실패하지만 문제로 보지 않는다.

## 검증과 한계

- `Tests/scripts/test_uninstall.sh`(가짜 HOME과 시스템 명령):
  - dry-run은 지우지 않음
  - `--yes`가 파일·설정·여섯 권한을 지우고 백업을 남김
  - `--no-backup`
  - 다른 앱 보존
  - `--check` 전후
  - 터미널 없이는 지우지 않음
  - 앱 없이 켜진 입력 소스는 실패와 안내
  - 잘못된 인자
- `WorkerCommandTests`: 작업 모드 인자.
- 입력 소스 끄기·로그인 항목 해제·권한 초기화는 실제 Mac에서만 확인할 수 있다. 결과는 아래 "실제 실행"에 남긴다.

## 실제 실행

2026-10-06, macOS 26.6.2 (25G83), KeyHue 0.2.5·빌드 97(개발 인증서 서명).

**첫 실행: 해제 단계는 됐지만 네 가지가 남았다.**

- 해제 단계 결과:
  - ABC로 전환
  - 한글·영문·부모 끄기(`status=0`)
  - 로그인 항목 해제
  - 파일 삭제
- 남은 것과 수정:
  1. **설정:** `defaults delete` 뒤에도 빈 plist(42바이트)가 남아 도메인 목록에 보였다. 지운 뒤 `~/Library/Preferences/<도메인>.plist`도 지운다.
  2. **입력 소스:** 영문 모드는 끄기에 `status=0`으로 답했는데 `AppleEnabledThirdPartyInputSources`에 남았다. 번들까지 지운 뒤라 TIS로는 다시 끌 수 없었다. 이 목록에서 KeyHue 항목만 빼고, 그 전에 목록을 백업한다.
  3. **로그인 항목:** 해제 후에도 Background Task Management 기록이 `[disabled]`로 남는다. 켜져 있는(`[enabled`) 것만 남은 것으로 본다.
  4. **입력기 권한:** 번들을 지운 뒤에는 `tccutil`이 번들 ID를 찾지 못했다(`-10814`). 권한 초기화를 파일 삭제 전으로 옮긴다. 남은 사본(설치본·앱 안 원본·저장소 `build/`)을 LaunchServices에 등록한 뒤 초기화한다. 저장소 사본은 다시 등록 해제한다.
- 이 실행에서 실제로 남아 있던 입력기의 손쉬운 사용 권한은 `build/` 사본을 등록해 초기화했다.

**고친 스크립트로 다시 실행:** 남은 설정을 지우고 두 번들의 여섯 권한을 모두 초기화했다. 이어서 `--check`가 "남긴 것이 없습니다"였다. `com.apple.HIToolbox`의 입력 소스 기록에도 KeyHue 항목이 없었다.
