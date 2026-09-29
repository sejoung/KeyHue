# 0006. State Bar는 화면별 non-activating NSPanel로 그린다

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
State Bar는 모든 Space/Full Screen 앱 위에 보이되 마우스·키보드·포커스를 절대 가로채면 안 된다. 멀티 모니터와 연결/해제, 해상도 변경에도 대응해야 한다.

## 결정
- 화면(`CGDirectDisplayID`)마다 `StateBarPanel`(NSPanel) 하나.
  - `styleMask: [.borderless, .nonactivatingPanel]`, `canBecomeKey/Main = false`
  - `ignoresMouseEvents = true`, `hasShadow = false`, `isOpaque = false`, `animationBehavior = .none`
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
  - `level = .statusBar` — Dock(.dock) 위에 보이되 시스템 alert/스크린세이버보다 아래.
- 그리기: 별도 view 없이 `backgroundColor`만 바꾼다(레이어 애니메이션 없음, 텍스트 없음).
- 위치: `screen.frame` 최하단, 높이는 설정값(기본 3px, 1–12px).
- 재배치 트리거: `NSApplication.didChangeScreenParametersNotification`(연결/해제/해상도), Space 변경 시 `orderFrontRegardless`.
- 멀티 모니터 정책(Phase 2): `All Displays` / `Active Display Only`. 활성 화면은 활성 앱 최전면 윈도우의 bounds를 `CGWindowListCopyWindowInfo`로 얻어 겹치는 면적이 가장 큰 화면으로 정한다. 윈도우 제목은 읽지 않으므로 Screen Recording 권한이 필요 없다.

## 결과
- 실측: 내장 + 외부 모니터에 각각 3px 패널이 layer 25로 올라간 것을 확인했다.
- `.statusBar` 레벨이 Full Screen/Mission Control에서 과하게 덮는지는 명세 §7 목록으로 수동 검증이 필요하다. 문제가 있으면 레벨만 조정한다.
- Active Display 정책은 앱 전환/Space 변경/입력 상태 변경 시점에만 화면을 다시 계산하므로, 같은 앱의 윈도우를 다른 모니터로 옮기기만 하면 다음 이벤트까지 이전 화면에 남는다(polling 금지와의 트레이드오프).
