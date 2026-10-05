# Architecture Decision Records

KeyHue의 주요 설계 결정을 기록한다. 형식은 [0001](0001-record-architecture-decisions.md)을 따른다.

| # | 결정 | 상태 |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | ADR로 설계 결정을 기록한다 | Accepted |
| [0002](0002-swiftpm-appkit-app-bundle-script.md) | SwiftPM + AppKit, 앱 번들은 스크립트로 조립한다 | Accepted (Dock 표시는 0020으로 갱신) |
| [0003](0003-core-module-and-event-flow.md) | 순수 로직(KeyHueCore)과 OS 연동(KeyHue)을 분리하고 단방향 이벤트 흐름을 쓴다 | Accepted (모듈 구성은 0022로 갱신) |
| [0004](0004-input-source-detection-via-tis.md) | Input Source는 TIS + distributed notification으로 감지한다 | Accepted (분류 규칙은 0013으로 대체) |
| [0005](0005-caps-lock-detection.md) | Caps Lock은 flagsChanged monitor + 시점 보정으로 감지한다 | Accepted |
| [0006](0006-state-bar-overlay-window.md) | State Bar는 화면별 non-activating NSPanel로 그린다 | Accepted (두께 범위·위치 옵션은 0012, 활성 화면은 0063으로 갱신) |
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
| [0017](0017-distribution-developer-id-notarization.md) | 릴리즈는 semver 태그(release.sh), 태그 push 시 Actions가 서명 없는 universal 빌드 게시 | Accepted (서명은 0021, 업데이트 확인은 0044로 갱신, 버전 형식 보완) |
| [0018](0018-open-source-mit.md) | MIT 라이선스로 공개, 이름·아이콘은 제외 | Accepted |
| [0019](0019-website-and-manual.md) | 다운로드 페이지·설명서는 site/ → GitHub Pages, 스크린샷은 앱이 직접 렌더링 | Accepted |
| [0020](0020-show-dock-icon-by-default.md) | Dock 아이콘을 기본으로 표시, 메뉴바 전용은 설정으로 | Accepted (Dock 기본값은 0038로 갱신) |
| [0021](0021-keep-permissions-across-builds.md) | 모든 빌드(로컬·릴리즈)를 같은 자체 서명 인증서로 서명해 권한 유지, 끊긴 권한은 앱이 알림 | Accepted (기존 키 파일 권한 보완) |
| [0022](0022-testing-strategy.md) | 판단 로직은 Core로 모으고 앱·스크립트·사이트·릴리즈 서명까지 자동 테스트 | Accepted (앱 쪽 판단 분리 보완) |
| [0023](0023-deliver-input-source-notifications-immediately.md) | 입력 소스 알림은 즉시 전달(deliverImmediately)로 받는다 | Accepted |
| [0024](0024-chameleon-hud.md) | 전환 HUD는 글자 대신 카멜레온을 입력 소스 색으로, 짧게 뜨고 빨리 사라진다 | Accepted (타이밍은 0025, 표시 화면은 0063으로 갱신) |
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
| [0035](0035-keep-test-artifacts.md) | 테스트 결과(로그·캡처)는 `.artifacts/<종류>/<시각>/`에 남기고, 마지막 실행은 링크로 연다 | Accepted (남기는 개수 하한 보완) |
| [0036](0036-diagnostic-log.md) | 문제를 나중에 확인할 수 있게 중요한 이벤트는 통합 로그(notice)와 로그 파일에 남긴다 | Accepted |
| [0037](0037-dont-undo-manual-switches.md) | 자동 전환 뒤 지켜보는 시간을 0.1초로 줄이고, 키 입력이 있으면 멈춘다 (직접 바꾼 것은 되돌리지 않는다) | Accepted (앱 전환 대기 중 수동 전환 보완) |
| [0038](0038-ux-cleanup.md) | Dock 표시는 기본으로 끄고, 메뉴는 자주 쓰는 것만 두며, 설정 창은 네 탭으로 나눈다 | Accepted (앱을 숨겨도 막대가 남도록 갱신) |
| [0039](0039-input-source-and-language-fallbacks.md) | 삭제된 입력 소스는 사용 가능한 대상으로 대체하고, 지원하지 않는 표시 언어는 영어로 보여 준다 | Accepted |
| [0040](0040-mistype-language-detection-phase0.md) | 잘못된 언어로 친 단어 판정(실험적): 0단계는 판정기와 말뭉치 측정만 만든다 | Accepted (앱 연결과 학습 말뭉치는 0041, 입력기 구성은 0045로 구체화) |
| [0041](0041-wrong-language-warning.md) | 잘못된 언어 경고(실험적, 1a단계): 단어가 끝나면 바꾼 단어를 메시지로 보여 주고 막대를 깜빡인다 | Accepted (판정 시점은 0042로 갱신, KeyHue 모드·다 지운 단어 재판정 보완) |
| [0042](0042-warn-while-typing.md) | 잘못된 언어 경고를 치는 중에 한다 (영어 접두사 + 설치된 명령어 이름) | Accepted (한글 모드 자음 규칙 추가) |
| [0043](0043-edge-cases-from-code-review.md) | 전체 코드 검토에서 찾은 엣지 케이스를 테스트로 고정하고 고친다 | Accepted (2026-10-03 항목 추가) |
| [0044](0044-update-check-and-release-link.md) | 하루 한 번 새 릴리즈를 확인하고 메뉴·일반 설정에서 알리며 설치는 사용자가 한다 | Accepted |
| [0045](0045-experimental-input-method-component.md) | 입력기는 같은 제품의 별도 앱으로 두고, 기본 입력과 자동 고침을 단계별로 검증한다 | Accepted (배포·설정 소유는 0051, 고침 기본값은 0064로 대체) |
| [0046](0046-shared-component-build-and-imk-spike.md) | 빌드·검증·패키징은 앱별 메타데이터로 공유하고 IMK 기술 검증 번들은 별도로 둔다 | Accepted (별도 배포·버전은 0051, 입력기 판정 모델 제외는 0064로 대체) |
| [0047](0047-component-aware-local-install.md) | 설치 명령은 앱별 종료·등록·실행 정책을 구분하고 비활성 IMK 실험 번들을 검증 후 교체한다 | Accepted (사용자 설치 흐름은 0051로 대체) |
| [0048](0048-current-syllable-composition-and-input-mode-icons.md) | 한글은 마지막 글자만 조합하고 입력 소스 메뉴는 투명한 가/A 아이콘으로 구분한다 | Accepted |
| [0049](0049-opt-in-input-method-integration.md) | 입력기 연동은 기본값을 보존하고 두 모드 유지·ABC 복구를 별도 실험 옵션으로 제공한다 | Accepted (실제 전환 호환성 검증 대기, 시스템 두벌식 짝 해석 보완, 세션 복구 단축키 예외는 0062) |
| [0050](0050-synchronize-imk-mode-before-key-events.md) | IMK 키 처리 전 실제 선택 모드를 동기화하고 같은 모드 콜백은 조합을 확정하지 않는다 | Accepted (실제 앱 재확인 대기, 조합 보존 보완) |
| [0051](0051-single-app-distribution-and-managed-input-method.md) | 입력기를 KeyHue 하나에 내장하고 앱에서 설치·업데이트·제거하며 영문도 한 글자만 조합한다 | Accepted (실제 설치·앱 호환성 검증 대기, 활성화·제거 시 비활성화는 0055로 대체) |
| [0052](0052-input-method-activation-and-single-app-scripts.md) | 설치 성공과 입력 소스 활성화를 구분하고 직접 추가 후 연동하며 별도 구성 요소 스크립트를 제거한다 | Accepted (자동 활성화는 0055로 대체) |
| [0053](0053-verify-input-modes-and-repair-owned-source-membership.md) | 두 모드 가용성을 기준으로 완료하고 macOS 26의 자기 입력 소스 멤버십·제거 잔여 항목을 복구한다 | Accepted (자기 멤버십 보완·잔여 항목 정리는 0055로 대체) |
| [0054](0054-verify-input-method-readiness-and-exercise-real-client.md) | parent와 두 mode의 실제 준비 상태를 확인하고 Cocoa 클라이언트에서 IMK 입력을 검증한다 | Accepted (순서대로 활성화는 0055로 대체, 진단 출력 읽기 보완) |
| [0055](0055-users-add-input-sources-manually.md) | 입력 소스는 사용자가 시스템 설정에서 추가하고 KeyHue는 설치·등록만 한다 | Accepted |
| [0056](0056-isolated-correction-and-undo-probe.md) | 확정 단어 교체·모드 전환·즉시 되돌리기는 전용 IMK 테스트 앱에서 먼저 실험한다 | Accepted (제품 고침 옵션은 미구현) |
| [0057](0057-automatic-correction-observation-and-input-priority.md) | 고침 결과는 자동 관찰하고 다음 입력이 대기 작업을 중단한다 | Accepted (격리된 실제 검사 통과) |
| [0058](0058-external-mode-callbacks-and-native-editor-acceptance.md) | 외부 모드 요청은 대기 고침을 취소하고 기본 입력은 실제 편집기로 검사한다 | Accepted (외부 전환 조합 보존은 0059로 보완) |
| [0059](0059-finalize-composition-on-input-source-change.md) | 외부 입력 소스 변경 알림에서 검증된 조합만 확정한다 | Accepted (TextEdit 이탈 경로 검증, 진입·콜드 스타트는 별도 과제) |
| [0060](0060-input-method-entry-and-cold-start-acceptance.md) | 입력기 진입 준비는 실제 첫 키와 새 서버 프로세스로 검증한다 | Accepted (메뉴·설정된 단축키 검사, 콜드 진입 원인 해석은 0061로 정정) |
| [0061](0061-external-selection-does-not-open-input-method-session.md) | 외부 TIS 선택은 연결되지 않은 클라이언트에 입력기 세션을 만들지 않는다 | Accepted (검사 로그 분리·새 클라이언트 검사, 제품 우회는 0062) |
| [0062](0062-repair-input-method-session-with-previous-source-shortcut.md) | 입력기 세션이 확인되지 않으면 사용자의 이전 입력 소스 단축키를 두 번 누른다 | Accepted (Core·유틸리티 구현, 실제 TextEdit 새 클라이언트·서버 재시작 검사 통과) |
| [0063](0063-notices-follow-keyboard-focus-screen.md) | 전환 HUD·한/영 경고 메시지·활성 모니터 막대는 키보드 포커스가 있는 화면을 따른다 | Accepted |
| [0064](0064-correction-modes-off-manual-automatic.md) | 입력기 단어 고침은 끄기·수동·자동 세 가지로 고르고, 기본은 수동이다 | Accepted (구현 완료, 테스트 앱·TextEdit 수동·자동 실제 검사 통과. 앱별 허용은 0065, 수동 신호는 0068로 대체) |
| [0065](0065-correct-all-apps-with-feedback.md) | 단어 고침은 모든 앱을 대상으로 하고, 실패와 오탐은 사용자에게 보여 주고 사용자가 보고하게 한다 | Accepted (구현 완료, 테스트 앱·TextEdit 실제 검사 통과. 다른 앱 확인 남음) |
| [0066](0066-ghostty-commit-after-tab-and-navigation-keys.md) | Ghostty에서는 조합 중 Tab·이동 키가 조합을 키와 따로 확정한다 | Accepted (구현·단위 테스트·Ghostty 실제 키 검사 완료) |
| [0067](0067-bidirectional-correction-and-terminals.md) | 단어 고침은 한/영 양방향으로 하고, 터미널은 키로 지우고 다시 넣는다 | Accepted (수동 고침 방식은 0068로 대체. 구현·단위 테스트·TextEdit 실제 검사 완료, Ghostty 고침은 0068 단축키로 검사 완료) |
| [0068](0068-fix-words-with-a-shortcut.md) | 단어 고침은 사용자가 단축키로 요청할 때 한다 | Accepted (구현·단위 테스트·TextEdit·Ghostty 실제 검사 완료) |

입력기 개발의 범위·세션 계약·단계별 완료 기준은 [실험적 입력기 설계](../INPUT_METHOD_DESIGN.md)를 따른다.
T단계 진행과 자동/수동 검증 결과는 [IMK 기술 검증 기록](../INPUT_METHOD_SPIKE.md)에 남긴다.
