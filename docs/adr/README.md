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
| [0007](0007-auto-reset-policy.md) | ABC 자동 전환 정책: 기본 OFF, 지연 전환 + 1회 검증 | Accepted (전환 대상은 0013, 옵션 형태는 0029로 대체, 타이밍은 0031로 갱신) |
| [0008](0008-escape-detection-listen-only-event-tap.md) | ESC는 listen-only CGEventTap(Input Monitoring)으로 감지한다 | Accepted |
| [0009](0009-phase2-features-opt-in.md) | Phase 2 기능은 모두 opt-in으로 함께 제공한다 | Accepted |
| [0010](0010-settings-and-launch-at-login.md) | 설정은 UserDefaults, Launch at Login은 SMAppService | Accepted (저장 방식 0014, 메뉴 언어 0016으로 갱신) |
| [0011](0011-chameleon-menu-bar-icon.md) | 메뉴바 아이콘은 카멜레온 실루엣을 상태색으로 칠한다 | Accepted |
| [0012](0012-bar-position-opacity-thickness.md) | State Bar 위치·불투명도·두께를 설정 가능하게 (기본은 하단 유지) | Accepted |
| [0013](0013-per-input-source-colors.md) | 한/영 고정 상태를 입력 소스별 색으로 일반화, "ABC"를 "기본 입력 소스"로 | Accepted (HUD 글자는 0024로 대체) |
| [0014](0014-store-only-changed-settings.md) | 설정은 기본값과 다른 값만 저장한다 | Accepted |
| [0015](0015-settings-window-swiftui.md) | 입력 소스별 설정을 위해 SwiftUI 설정 창을 둔다 | Accepted |
| [0016](0016-localization-strings-in-bundle.md) | UI 번역은 .lproj/Localizable.strings, 앱 안에서 언어 선택 | Accepted |
| [0017](0017-distribution-developer-id-notarization.md) | 릴리즈는 semver 태그(release.sh), 태그 push 시 Actions가 서명 없는 universal 빌드 게시 | Accepted |
| [0018](0018-open-source-mit.md) | MIT 라이선스로 공개, 이름·아이콘은 제외 | Accepted |
| [0019](0019-website-and-manual.md) | 다운로드 페이지·설명서는 site/ → GitHub Pages, 스크린샷은 앱이 직접 렌더링 | Accepted |
| [0020](0020-show-dock-icon-by-default.md) | Dock 아이콘을 기본으로 표시, 메뉴바 전용은 설정으로 | Accepted (Dock 기본값은 0038로 갱신) |
| [0021](0021-keep-permissions-across-builds.md) | 모든 빌드(로컬·릴리즈)를 같은 자체 서명 인증서로 서명해 권한 유지, 끊긴 권한은 앱이 알림 | Accepted |
| [0022](0022-testing-strategy.md) | 판단 로직은 Core로 모으고 앱·스크립트·사이트·릴리즈 서명까지 자동 테스트 | Accepted |
| [0023](0023-deliver-input-source-notifications-immediately.md) | 입력 소스 알림은 즉시 전달(deliverImmediately)로 받는다 | Accepted |
| [0024](0024-chameleon-hud.md) | 전환 HUD는 글자 대신 카멜레온을 입력 소스 색으로, 짧게 뜨고 빨리 사라진다 | Accepted (타이밍은 0025로 갱신) |
| [0025](0025-hud-appears-gently-leaves-fast.md) | HUD는 부드럽게 나타나고 바로 사라지며, 타이핑하면 즉시 숨는다 | Accepted (나타나는 방식은 0032로 갱신) |
| [0026](0026-no-wall-clock-waits-in-tests.md) | 타이밍 테스트는 실제 시간을 기다리지 않고 가짜 시간을 주입한다 | Accepted |
| [0027](0027-reset-on-window-switch.md) | 같은 앱 안에서 창을 바꾸면 기본 입력 소스로 전환 (메인 창 변경 기준) | Accepted (옵션 형태는 0029로 대체, 대기 시간은 0031로 갱신) |
| [0028](0028-remember-input-per-window.md) | 창마다 입력 소스를 기억한다 (AX 창 동일성, 앱 실행 중에만) | Accepted (대기 시간은 0031로 갱신) |
| [0029](0029-switch-behavior-per-situation.md) | 앱·창을 바꿀 때 "그대로 / 기본 입력 소스로 전환 / 마지막 입력 소스로 복원" 중 하나를 고른다 | Accepted |
| [0030](0030-bounded-accessibility-requests.md) | 손쉬운 사용 요청은 짧게 끊고, 켜진 옵션에 필요한 것만 관찰한다 | Accepted |
| [0031](0031-faster-app-switch.md) | 앱 전환 뒤 대기를 40 ms로 줄이고, 덮어쓰기는 알림을 받는 즉시 바로잡는다 | Accepted (지켜보는 시간은 0037로 갱신) |
| [0032](0032-hud-appears-instantly.md) | HUD는 전환하는 순간 바로 나타난다 (페이드 인 없음) | Accepted |
| [0033](0033-retry-accessibility-attach-while-launching.md) | 막 실행된 앱에는 잠시 뒤 다시 붙는다 (손쉬운 사용 알림 등록 재시도) | Accepted |
| [0034](0034-hide-macos-input-indicator.md) | macOS 입력 소스 표시(커서 옆 배지)를 숨기는 옵션을 둔다 (기본은 건드리지 않음) | Accepted |
| [0035](0035-keep-test-artifacts.md) | 테스트 결과(로그·캡처)는 `.artifacts/<종류>/<시각>/`에 남기고, 마지막 실행은 링크로 연다 | Accepted |
| [0036](0036-diagnostic-log.md) | 문제를 나중에 확인할 수 있게 중요한 이벤트는 통합 로그(notice)와 로그 파일에 남긴다 | Accepted |
| [0037](0037-dont-undo-manual-switches.md) | 자동 전환 뒤 지켜보는 시간을 0.1초로 줄이고, 키 입력이 있으면 멈춘다 (직접 바꾼 것은 되돌리지 않는다) | Accepted |
| [0038](0038-ux-cleanup.md) | Dock 표시는 기본으로 끄고, 메뉴는 자주 쓰는 것만 두며, 설정 창은 네 탭으로 나눈다 | Accepted (앱을 숨겨도 막대가 남도록 갱신) |
| [0039](0039-input-source-and-language-fallbacks.md) | 삭제된 입력 소스는 사용 가능한 대상으로 대체하고, 지원하지 않는 표시 언어는 영어로 보여 준다 | Accepted |
| [0040](0040-mistype-language-detection-phase0.md) | 잘못된 언어로 친 단어 판정(실험적): 0단계는 판정기와 말뭉치 측정만 만든다 | Accepted (앱 연결과 학습 말뭉치는 0041로 갱신) |
| [0041](0041-wrong-language-warning.md) | 잘못된 언어 경고(실험적, 1a단계): 단어가 끝나면 바꾼 단어를 메시지로 보여 주고 막대를 깜빡인다 | Accepted (판정 시점은 0042로 갱신) |
| [0042](0042-warn-while-typing.md) | 잘못된 언어 경고를 치는 중에 한다 (영어 접두사 + 설치된 명령어 이름) | Accepted |
