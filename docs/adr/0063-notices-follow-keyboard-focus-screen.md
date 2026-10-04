# 0063. 전환 HUD·한/영 경고 메시지·활성 모니터 막대는 키보드 포커스가 있는 화면을 따른다

- 상태: Accepted
- 날짜: 2026-10-04
- 관련: [0006](0006-state-bar-overlay-window.md), [0024](0024-chameleon-hud.md)

## 맥락
여러 모니터에서 전환 HUD가 포커스된 모니터가 아닌 다른 모니터에 떴다. "활성 모니터에만 표시" 정책의 막대도 같은 이유로 이전 모니터에 남았다([ADR 0006](0006-state-bar-overlay-window.md)의 알려진 제약).

[ADR 0024](0024-chameleon-hud.md)는 표시를 늦추지 않으려고 앱 전환·Space 변경 때 창 목록(`CGWindowListCopyWindowInfo`)으로 활성 화면을 구해 두고 그 값을 썼다. 같은 앱의 창이 여러 모니터에 있으면 앱 전환 없이 다른 모니터 창으로 포커스가 옮겨진다(터미널·브라우저 창, Rectangle 같은 창 이동). 이때 구해 둔 화면은 낡는다. 앱 전환 직후에는 창 목록이 아직 앞 창을 보여 주지 않을 수도 있다.

2026-10-04 모니터 세 대(주 화면 왼쪽에 외부 두 대, 모니터별 Space 켬)에서 실험했다. 계속 실행 중인 background accessory 프로세스가 50ms마다 값을 읽는 동안 TextEdit 창 두 개를 서로 다른 모니터에 두고 앱 전환 없이 번갈아 앞으로 가져왔다. `NSScreen.main`은 매번 앞 창의 모니터로 바뀌었고, 창 목록으로 구한 화면과 같은 시점에 바뀌었다. 창 목록 조회는 이 환경에서 중앙값 1.5ms, 최대 31ms였다.

같은 방식으로 NSWorkspace·앱·distributed 알림을 모두 기록했다. 포커스가 다른 모니터 창으로 옮겨질 때마다 공개 상수가 없는 `NSWorkspaceActiveDisplayDidChangeNotification`이 왔고(세 번 왕복 모두), 받는 시점에 `NSScreen.main`은 이미 새 모니터였다.

## 결정
- 전환 HUD와 한/영 경고 메시지의 화면은 **표시하는 순간** 구한다(`ActiveScreenLocator.focusedScreen`).
- 순서는 다음과 같다(`ScreenGeometry.focusedScreenIndex`).
  1. 키보드 포커스가 있는 화면(`NSScreen.main`). 창 목록을 조회하지 않으므로 ADR 0024의 "표시 순간 창 목록 조회 없음"은 유지된다.
  2. 앱 전환 때 구해 둔 활성 화면.
  3. 주 화면.
  
  연결되지 않은 화면은 건너뛴다.
- 위치는 고른 화면 사용 가능 영역의 가운데 아래다(`ScreenGeometry.hudFrame`). HUD와 메시지가 같은 계산을 쓴다.
- 활성 모니터 막대도 같은 순서로 화면을 고른다. 다음 시점에 다시 고른다.
  - 앱 전환·Space 변경 때. 이때는 이전처럼 활성 앱 창 화면을 구한다.
  - `NSWorkspaceActiveDisplayDidChangeNotification`을 받았을 때(`AppFocusMonitor.onActiveDisplayChanged`). 이 경우 창 목록은 조회하지 않는다. polling은 하지 않는다(ADR 0006).
- 위 알림은 문서화되지 않은 이름이다. 오지 않는 OS에서는 막대가 앱 전환·Space 변경 때만 갱신되는 이전 동작으로 돌아간다. HUD·메시지는 표시 순간 고르므로 영향이 없다.

## 결과
- Core 테스트(`ScreenGeometryTests`)가 다음을 고정한다.
  - 같은 앱의 다른 모니터 창으로 옮긴 경우 앱 전환 때 구한 화면보다 포커스 화면이 우선한다.
  - 포커스 화면이 없으면 활성 화면으로 대체한다.
  - 빠진 모니터를 건너뛴다.
  - 화면이 없으면 표시하지 않는다.
  - HUD frame 위치를 검사한다.
- 앱 테스트는 활성 모니터 정책의 막대가 모니터마다 넘겨받은 화면으로 옮겨지는지, `AppFocusMonitor`가 포커스 모니터 변경 알림을 전달하고 정지 뒤에는 전달하지 않는지 검사한다.
- 앱 테스트(`AppIntegrationTests`)는 연결된 모니터마다 HUD가 넘겨받은 화면 안 위치에 놓이는지, 표시용 화면 선택이 포커스 화면을 우선하는지 검사한다.
- 모니터별 Space를 끈 환경은 실험하지 않았다. `NSScreen.main`이 포커스를 따르지 않으면 이전처럼 앱 전환 때 구한 화면 문제가 남을 수 있다.
- 포커스를 바꾸지 않고 창만 다른 모니터로 옮기면(Rectangle 단축키 등) 포커스 모니터 변경 알림이 오는지는 실험하지 않았다.
