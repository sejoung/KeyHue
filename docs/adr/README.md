# Architecture Decision Records

KeyHue의 주요 설계 결정을 기록한다. 형식은 [0001](0001-record-architecture-decisions.md)을 따른다.

| # | 결정 | 상태 |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | ADR로 설계 결정을 기록한다 | Accepted |
| [0002](0002-swiftpm-appkit-app-bundle-script.md) | SwiftPM + AppKit, 앱 번들은 스크립트로 조립한다 | Accepted (Dock 표시는 0020으로 갱신) |
| [0003](0003-core-module-and-event-flow.md) | 순수 로직(KeyHueCore)과 OS 연동(KeyHue)을 분리하고 단방향 이벤트 흐름을 쓴다 | Accepted (모듈 구성은 0022로 갱신) |
| [0004](0004-input-source-detection-via-tis.md) | Input Source는 TIS + distributed notification으로 감지한다 | Accepted (분류 규칙은 0013으로 대체) |
| [0005](0005-caps-lock-detection.md) | Caps Lock은 flagsChanged monitor + 시점 보정으로 감지한다 | Accepted |
| [0006](0006-state-bar-overlay-window.md) | State Bar는 화면별 non-activating NSPanel로 그린다 | Accepted (두께 범위·위치 옵션은 0012로 갱신) |
| [0007](0007-auto-reset-policy.md) | ABC 자동 전환 정책: 기본 OFF, 지연 전환 + 1회 검증 | Accepted (전환 대상은 0013으로 대체) |
| [0008](0008-escape-detection-listen-only-event-tap.md) | ESC는 listen-only CGEventTap(Input Monitoring)으로 감지한다 | Accepted |
| [0009](0009-phase2-features-opt-in.md) | Phase 2 기능은 모두 opt-in으로 함께 제공한다 | Accepted |
| [0010](0010-settings-and-launch-at-login.md) | 설정은 UserDefaults, Launch at Login은 SMAppService | Accepted (저장 방식 0014, 메뉴 언어 0016으로 갱신) |
| [0011](0011-chameleon-menu-bar-icon.md) | 메뉴바 아이콘은 카멜레온 실루엣을 상태색으로 칠한다 | Accepted |
| [0012](0012-bar-position-opacity-thickness.md) | State Bar 위치·불투명도·두께를 설정 가능하게 (기본은 하단 유지) | Accepted |
| [0013](0013-per-input-source-colors.md) | 한/영 고정 상태를 입력 소스별 색으로 일반화, "ABC"를 "기본 입력 소스"로 | Accepted |
| [0014](0014-store-only-changed-settings.md) | 설정은 기본값과 다른 값만 저장한다 | Accepted |
| [0015](0015-settings-window-swiftui.md) | 입력 소스별 설정을 위해 SwiftUI 설정 창을 둔다 | Accepted |
| [0016](0016-localization-strings-in-bundle.md) | UI 번역은 .lproj/Localizable.strings, 앱 안에서 언어 선택 | Accepted |
| [0017](0017-distribution-developer-id-notarization.md) | 릴리즈는 semver 태그(release.sh), 태그 push 시 Actions가 서명 없는 universal 빌드 게시 | Accepted |
| [0018](0018-open-source-mit.md) | MIT 라이선스로 공개, 이름·아이콘은 제외 | Accepted |
| [0019](0019-website-and-manual.md) | 다운로드 페이지·설명서는 site/ → GitHub Pages, 스크린샷은 앱이 직접 렌더링 | Accepted |
| [0020](0020-show-dock-icon-by-default.md) | Dock 아이콘을 기본으로 표시, 메뉴바 전용은 설정으로 | Accepted |
| [0021](0021-keep-permissions-across-builds.md) | 모든 빌드(로컬·릴리즈)를 같은 자체 서명 인증서로 서명해 권한 유지, 끊긴 권한은 앱이 알림 | Accepted |
| [0022](0022-testing-strategy.md) | 판단 로직은 Core로 모으고 앱·스크립트·사이트·릴리즈 서명까지 자동 테스트 | Accepted |
