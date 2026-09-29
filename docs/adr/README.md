# Architecture Decision Records

KeyHue의 주요 설계 결정을 기록한다. 형식은 [0001](0001-record-architecture-decisions.md)을 따른다.

| # | 결정 | 상태 |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | ADR로 설계 결정을 기록한다 | Accepted |
| [0002](0002-swiftpm-appkit-app-bundle-script.md) | SwiftPM + AppKit, 앱 번들은 스크립트로 조립한다 | Accepted |
| [0003](0003-core-module-and-event-flow.md) | 순수 로직(KeyHueCore)과 OS 연동(KeyHue)을 분리하고 단방향 이벤트 흐름을 쓴다 | Accepted |
| [0004](0004-input-source-detection-via-tis.md) | Input Source는 TIS + distributed notification으로 감지한다 | Accepted |
| [0005](0005-caps-lock-detection.md) | Caps Lock은 flagsChanged monitor + 시점 보정으로 감지한다 | Accepted |
| [0006](0006-state-bar-overlay-window.md) | State Bar는 화면별 non-activating NSPanel로 그린다 | Accepted |
| [0007](0007-auto-reset-policy.md) | ABC 자동 전환 정책: 기본 OFF, 지연 전환 + 1회 검증 | Accepted |
| [0008](0008-escape-detection-listen-only-event-tap.md) | ESC는 listen-only CGEventTap(Input Monitoring)으로 감지한다 | Accepted |
| [0009](0009-phase2-features-opt-in.md) | Phase 2 기능은 모두 opt-in으로 함께 제공한다 | Accepted |
| [0010](0010-settings-and-launch-at-login.md) | 설정은 UserDefaults, Launch at Login은 SMAppService | Accepted |
