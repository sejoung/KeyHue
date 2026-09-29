# 0026. 타이밍 테스트는 실제 시간을 기다리지 않고 가짜 시간을 주입한다

- 상태: Accepted (ADR 0022의 테스트 전략을 보완)
- 날짜: 2026-09-29

## 맥락
v0.1.6 릴리즈 workflow가 `swift test`에서 실패해 릴리즈가 게시되지 않았다.

```text
✘ Test rapidSwitchesKeepItVisible() recorded an issue: Expectation failed: hud.isShowing → false
```

- HUD 테스트는 `Task.sleep`으로 실제 시간을 기다렸다.
- ADR 0025에서 타이밍을 바꾼 뒤, 이 테스트는 "두 번째 표시 후 0.315초에 아직 보이는가"를 확인했다. 그런데 두 번째 표시의 숨김 예약은 0.3초 뒤라서 여유가 **15ms**뿐이었다.
- 로컬에서는 통과했지만, GitHub 러너에서는 sleep이 조금만 늦게 깨어나도 실패했다. 테스트가 결과를 CPU 속도에 맡긴 것이다.

## 결정
- **테스트에서 실제 시간을 기다리지 않는다**(`Task.sleep`, `RunLoop.run(until:)`로 타이밍 확인 금지).
- 시간에 따라 동작하는 코드는 Core의 `Scheduling`을 주입받는다.
  - 앱: `MainQueueScheduler`(main queue의 1회성 예약)
  - 테스트: `FakeScheduler`(`advance(by:)`로 시간을 흘림)
  - `AutoResetCoordinator`(ADR 0022)에 이어 `HUDController`의 숨김 예약도 이 방식으로 바꿨다.
- 경계 확인은 예약 시각 바로 전(`- 0.01`)과 그 시각에서 결정적으로 한다.
- 예외: 애니메이션 자체(NSAnimationContext)는 테스트 대상이 아니다. 테스트는 상태(`isShowing`)와 예약만 본다. 페이드 아웃이 시작되면 `isShowing = false`다.

## 결과
- HUD 테스트가 실제 시간 대기 없이 결정적으로 돈다. 앱 통합 테스트 시간은 2.8초에서 0.16초로 줄었다.
- 10코어를 모두 점유한 CPU 부하 속에서 앱 통합 테스트를 20번 연속 돌려 모두 통과했다.
- v0.1.6 태그는 릴리즈 없이 남는다. 수정은 다음 patch 릴리즈(v0.1.7)로 게시한다.
