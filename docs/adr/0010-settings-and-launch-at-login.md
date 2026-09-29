# 0010. 설정은 UserDefaults, Launch at Login은 SMAppService

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
명세는 DB 없이 `UserDefaults`, 로그인 시 실행은 `SMAppService.mainApp`을 요구한다. 설정 UI는 메뉴바 메뉴로 충분하다.

## 결정
- `KeyHueSettings`(값 타입) + `SettingsStore`(UserDefaults 저장, 변경 시에만 observer 호출).
  - 색상은 `#RRGGBB(AA)` 문자열로 저장한다. 잘못된 값은 기본값으로 대체한다.
  - 두께는 1–12px로 clamp한다. 메뉴 선택지는 1/2/3/4/6/8px. (0012에서 1–16px로 확장, 위치·불투명도 추가)
- Launch at Login은 **UserDefaults에 저장하지 않는다.** 사용자가 System Settings에서 끌 수도 있으므로 `SMAppService.mainApp.status`를 유일한 원본으로 삼고 메뉴를 열 때마다 읽는다. `requiresApproval`이면 Login Items 설정을 연다. 실패 시 alert로 오류를 보여준다.
- 설정 화면은 별도 윈도우 없이 메뉴바 메뉴로 제공한다(Show State Bar, 자동 전환 옵션, Bar Position, Bar Thickness, Bar Opacity, Colors(프리셋 + Custom… NSColorPanel + Reset), Displays, Phase 2 옵션, Launch at Login, About, Quit).
- 메뉴 텍스트는 영어로 둔다(명세의 메뉴 예시와 동일).

## 결과
- 설정 파일/DB/네트워크가 없어 Disk I/O는 설정 변경 시에만 발생한다.
- `SMAppService.mainApp`은 `.app` 번들로 실행될 때만 동작한다. `swift run`으로 실행하면 등록에 실패하고 오류 alert가 뜬다.
