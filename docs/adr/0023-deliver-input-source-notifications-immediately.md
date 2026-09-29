# 0023. 입력 소스 알림은 즉시 전달(deliverImmediately)로 받는다

- 상태: Accepted (ADR 0004의 감지 방식을 보완)
- 날짜: 2026-09-29

## 맥락
"한/영 전환 후 색이 바뀌는 데 딜레이가 있다"는 제보가 있었다. 전환 시각, macOS 알림 도착 시각, KeyHue 반영 시각을 따로 재 보니 이랬다.

| | 결과 |
|---|---|
| macOS 알림 자체 (`deliverImmediately`로 받는 기준 수신기) | 항상 10–37ms |
| KeyHue 반영 | 대부분 20–40ms지만 **약 1/4이 0.7–1.5초 늦었고, 가끔 아예 놓쳤다** |

분포가 둘로 갈려서 처리가 느린 문제가 아니었다. 원인을 가려 보았다.
- App Nap: `NSAppSleepDisabled`로 꺼 봐도 그대로였다 → 원인 아님.
- **distributed notification 일시 중지**: `addObserver(forName:object:queue:using:)`(블록 API)는 기본 suspension behavior를 쓴다. 이 경우 앱이 비활성일 때 알림을 모아 두었다가 늦게 전달한다. KeyHue는 사용자가 다른 앱을 쓰는 동안, 즉 거의 항상 비활성 상태로 동작한다. Dock에 표시되는 일반 앱이 되면서(ADR 0020) 더 두드러졌을 수 있다.

## 결정
- `InputSourceMonitor`와 설정 창의 입력 소스 목록 구독은 selector API로 등록하고 `suspensionBehavior: .deliverImmediately`를 지정한다.
- 규칙 테스트(`NotificationDeliveryRuleTests`)가 앱 코드의 모든 `DistributedNotificationCenter` 구독이 블록 API가 아니고 `.deliverImmediately`인지 확인한다.
  - 테스트 프로세스는 일반 앱처럼 비활성 상태로 일시 중지되지 않아서, 동작 테스트로는 이 회귀를 잡을 수 없다. 그래서 규칙으로 막는다.
- `Tests/perf/input-latency.sh`: 실행 중인 KeyHue에서 한/영을 N번 바꾸며 macOS 알림 지연과 KeyHue 반영 지연을 비교한다. 허용치(기본 200ms)를 넘으면 실패한다. 로컬 전용이다(`docs/TESTING.md`).

## 결과
- 실측(11회 × 4번)

  | | 중앙값 | 최대 | 200ms 초과 |
  |---|---|---|---|
  | 변경 전 | 29ms | 1.5초(+ 놓침) | 약 1/4 |
  | 변경 후 | 23–29ms | 40ms | 0/44 |

  KeyHue 반영이 macOS 알림 도착과 거의 같아졌다.
- 남은 지연은 macOS 알림 자체(수십 ms)와 화면 갱신 한 프레임이다. "Caps Lock으로 ABC 전환"을 쓰면 macOS가 짧게 누름과 길게 누름을 구분하느라 전환 자체가 늦을 수 있다. 이것은 KeyHue 밖의 지연이다.
- 이벤트 기반 원칙은 그대로다. 즉시 전달은 알림이 올 때만 깨어나므로 대기 CPU에 영향이 없다.
