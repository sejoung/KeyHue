# KeyHue 테스트

자동 테스트로 확인하는 것과, 사람이 직접 확인해야 하는 것을 정리한다. 테스트 전략은 [ADR 0022](adr/0022-testing-strategy.md)에 있다.

## 한 번에 돌리기

```bash
scripts/verify.sh          # 빌드 → Swift 테스트 → lint → 스크립트 테스트 → 사이트 테스트 → 앱 번들
```

`scripts/release.sh`도 릴리즈 전에 이것을 실행한다.

## 테스트 결과 보기

로그·캡처·차이 이미지는 지우지 않고 `.artifacts/`에 실행마다 남긴다(git에 올리지 않음, [ADR 0035](adr/0035-keep-test-artifacts.md)).

```text
.artifacts/
  verify/<시각>/                   scripts/verify.sh 단계별 로그
  screenshots/<시각>/              screenshots.sh --check 렌더링 결과와 차이 이미지(*.diff.png)
  perf/<테스트 이름>/<시각>/        Tests/perf/*.sh의 summary.log, KeyHue 로그, 캡처
  <종류>/latest                    그 종류의 마지막 실행
  latest                           종류와 상관없이 마지막 실행
TestResults → .artifacts/latest    방금 돌린 테스트 결과를 바로 연다
```

- 종류마다 최근 20회만 남긴다(`ARTIFACTS_KEEP`로 바꿀 수 있다). 이전 실행과 비교하려면 `<종류>/` 아래 시각 폴더를 연다.
- 새 스크립트는 `source scripts/artifacts.sh` 뒤 `OUT="$(artifacts_dir perf/<이름>)"`으로 폴더를 받아 결과를 남긴다.
- KeyHue가 관여하는 성능 점검은 테스트하는 동안 쌓인 KeyHue 로그 파일 부분을 `keyhue-file.log`로 함께 남긴다(`keyhue_log_mark`/`keyhue_log_save`).

## 문제가 생겼을 때 로그 보기

KeyHue는 원인을 좇는 데 필요한 이벤트를 남긴다([ADR 0036](adr/0036-diagnostic-log.md)). 다시 재현하지 않아도 지난 기록을 볼 수 있다.

```bash
open -R ~/Library/Logs/KeyHue/KeyHue.log                                   # 메뉴 "로그 파일 보기"와 같다
/usr/bin/log show --last 1h --predicate 'subsystem == "KeyHue"' --style compact   # 통합 로그(notice 이상)
/usr/bin/log stream --predicate 'subsystem == "KeyHue"' --level debug --style compact  # 세부 사항까지 실시간
```

- 실행할 때마다 버전, macOS, 기본값과 다른 설정, 권한, 맨 앞 앱을 남긴다. 실행 직후에는 KeyHue 자신이 맨 앞인 경우가 많고, 그때는 다음 앱 활성화부터 관찰한다.
- 흐름의 예: `app activated` → `not ready … will retry` → `attached` → `window switched within …` → `auto reset: switched select(…) ok` → `caps=… source=…`

## 자동 테스트

계획 중인 정식 입력기의 검증은 [입력기 설계의 단계·완료 기준](INPUT_METHOD_DESIGN.md#8-단계와-완료-기준)과 [검증 계획](INPUT_METHOD_DESIGN.md#9-검증-계획)을 따른다. 현재 실험 코어와 통합 앱의 내장 서비스 메타데이터·설치 트랜잭션을 자동 검사하며, 실제 IMK 세션·앱 입력 호환성은 수동 검증 대상이다([실험 기록](INPUT_METHOD_SPIKE.md)).

| 종류 | 위치 | 실행 | 무엇을 확인하나 |
|---|---|---|---|
| Core 단위 | `Tests/KeyHueCoreTests` | `swift test` | 입력 소스 색·글리프, 두벌식 조합·오타 언어 판정, 상태 판정, 자동 전환 정책, **자동 전환 조정(지연·덮어쓰기·재시도, 가짜 시간으로 재현)**, 앱별·창별 기억, 권한 판단, 메뉴 상태, 설정 저장(바뀐 값만), 릴리즈 버전 비교·업데이트 확인 간격, 번역 파일 일관성 |
| IMK 실험 Core | `Tests/KeyHueInputMethodSpikeCoreTests` | `swift test` | 마지막 글자 조합/키 취소, 받침 이동·겹모음/겹받침, 결정적 표본의 클라이언트 편집 결과 보존, 한 번 확정, 모드·세션 분리, 영문 현재 한 글자 조합·여러 단어 원문 보존·Backspace·실제 모드 동기화 |
| 앱 번들 | `scripts/check-bundle.sh` | `scripts/verify.sh` | 통합 KeyHue와 내장 서비스의 ID·실행 파일·공통 버전/빌드·리소스·중첩 서명·내장 누락/불일치 거부, IMK 메타데이터·입력기/모드별 메뉴/설정 아이콘 참조/파일·표시 이름 번역·클래스/콜백 셀렉터 self-check. 설치·실제 서버 콜백·메뉴/설정 화면 표시는 포함하지 않음 |
| 앱 통합 | `Tests/KeyHueAppTests` | `swift test` | 실제 화면에 State Bar 패널 생성·위치·속성·색, 실제 입력 소스 조회(TIS), 번역 번들 적용, 설정 창 모델 바인딩·설치 액션 위임, 임시 폴더/가짜 OS로 입력기 설치·교체·실패 복구·활성 상태/종료 실패 거부·외부 번들/링크 거부·제거/재설치·원본 보존, 부모 활성화 후 새 모드 노출·오래된 핸들 방지·API 성공 후 비활성 확인·부모 상태와 두 모드 가용성 구분·고아 설정 항목 정리·macOS 26 자기 항목 보완의 타 소스 보존/알 수 없는 형식 거부/실패 복구·직접 추가 후 사용 요청 유지, 앱 메뉴 단축키, 업데이트 조회(가짜 네트워크·시간), 오류·캐시·24시간 간격 |
| 스크립트 | `Tests/scripts/test_*.sh` | `Tests/scripts/run.sh` | `release.sh` 전체 시나리오(임시 git 저장소 + 로컬 원격), `signing.sh`(키 파일·클립보드 순서), `release-notes.sh`, `install.sh`의 내장 앱 검증·복사 실패 복구, `test_bundle.sh`의 단일 앱 ZIP·버전/빌드/아이콘·구성 요소 인자 거부, `lint.sh`, `artifacts.sh`(결과 폴더·링크·정리) |
| lint | `scripts/lint.sh` | 〃 | ShellCheck, `$변수` 바로 뒤 한글(bash 3.2 버그) |
| 사이트 | `Tests/site/*.test.js` | `node --test Tests/site/*.test.js` | 데모의 문자 체계 판정, 내부 링크·이미지·앵커, 두 언어 설명서 목차 일치 |
| 릴리즈 서명 경로 | `Tests/ci/release-signing-check.sh` | CI 전용 | 일회용 키로 release.yml과 같은 순서의 서명(임시 키체인 → 해시 서명 → 부모와 내장 서비스가 같은 인증서인지 요구 조건 검사) |
| 한/영 반영 지연 | `Tests/perf/input-latency.sh` | 로컬(실행 중인 KeyHue) | 입력 소스를 실제로 바꾸며 macOS 알림 지연과 KeyHue 반영 지연 비교, 200ms 초과 시 실패 ([ADR 0023](adr/0023-deliver-input-source-notifications-immediately.md)) |
| 멈춘 앱 대기 | `Tests/perf/ax-timeout.sh` | 로컬(터미널에 손쉬운 사용 권한) | 직접 띄운 테스트 앱을 정지시키고 AX 요청 대기 시간을 비교, KeyHue 설정(0.25초)으로 0.5초 안에 끊기지 않으면 실패 ([ADR 0030](adr/0030-bounded-accessibility-requests.md)) |
| 앱 전환 지연 | `Tests/perf/app-switch-latency.sh` | 로컬(실행 중인 KeyHue) | 측정용 앱 두 개를 번갈아 활성화하며 KeyHue가 ABC로 바꾸기까지의 지연·깜빡임을 잼. 실패·깜빡임이 있거나 중앙값 100ms 초과 시 실패. 측정 중에만 "앱을 바꿀 때"를 바꾸고 되돌림. `race` 모드는 KeyHue 없이 시스템 덮어쓰기 재현 ([ADR 0031](adr/0031-faster-app-switch.md)) |
| 실행 직후 창 전환 | `Tests/perf/window-switch-after-launch.sh` | 로컬(실행 중인 KeyHue, 터미널에 손쉬운 사용 권한) | 창 두 개짜리 측정용 앱을 매번 새로 띄우고 곧바로 창을 두 번 바꿔, KeyHue보다 늦게 실행된 앱에서도 창 전환을 감지하는지 확인. 놓친 회차가 있으면 실패. "창을 바꿀 때"가 켜져 있어야 하고, 측정 중에는 화면을 잠그거나 다른 앱을 쓰지 않는다 ([ADR 0033](adr/0033-retry-accessibility-attach-while-launching.md)) |
| macOS 입력 소스 표시 | `Tests/perf/input-indicator.sh` | 로컬(터미널에 화면 기록 권한) | 측정용 앱을 띄운 채 macOS 설정을 표시 → 숨김으로 바꾸며 그 창만 캡처해, 실행 중인 앱에 바로 적용되는지 확인. 캡처는 결과 폴더에 남고, 원래 설정으로 되돌림 ([ADR 0034](adr/0034-hide-macos-input-indicator.md)) |
| 오타 언어 판정 | `Tests/perf/mistype-eval.sh` | 로컬(처음 한 번 말뭉치 내려받기) | 앱에 넣는 음절 모델(`Resources/Mistype/`, `scripts/build-mistype-model.sh`로 생성)로 영문 모드로 친 한글·한글 모드로 친 영어의 검출률과 1,000단어당 오탐을 단어 끝 판정과 치는 중 판정(키를 하나씩 쳐서 몇 타째에 알리는지)으로 공개 말뭉치(한국어 뉴스·대화체, 영어 뉴스·위키, 저장소 코드)로 재고 임계값별 표·추천 설정·오탐 예시를 남김. `--latin shell=$HOME/.zsh_history`처럼 내 말뭉치를 더할 수 있다 결정에 쓴 보고서는 `docs/adr/data/`에 남긴다 ([ADR 0040](adr/0040-mistype-language-detection-phase0.md), [0041](adr/0041-wrong-language-warning.md), [0042](adr/0042-warn-while-typing.md)) |
| 설정 창 모양 | `scripts/screenshots.sh --check` | 로컬 | 실제 SwiftUI 설정 창을 다시 렌더링해 커밋된 이미지와 비교(0.5% 넘게 다르면 실패, 렌더링 결과와 차이 이미지는 `.artifacts/screenshots/`에 남음) |

**타이밍 테스트 규칙**: 실제 시간을 기다리지 않는다(`Task.sleep` 금지). 시간에 따라 동작하는 코드는 `Scheduling`을 주입받고 테스트는 `FakeScheduler`로 시간을 흘린다. 느린 CI에서 흔들리는 테스트가 v0.1.6 릴리즈를 막은 적이 있다([ADR 0026](adr/0026-no-wall-clock-waits-in-tests.md)).

CI(`.github/workflows/ci.yml`)
- **macOS**: `scripts/verify.sh`
- **Ubuntu**: ShellCheck 필수 lint, 사이트 테스트
- **macOS**: 릴리즈 서명 경로

설정 창 모양 비교는 macOS 버전마다 렌더링이 조금씩 달라 CI에서는 돌리지 않는다. UI를 바꿨다면 로컬에서 `--check`로 확인하고, 의도한 변경이면 `scripts/screenshots.sh`로 이미지를 갱신한다.

## 수동 테스트 (릴리즈 전 체크리스트)

권한 허용, Gatekeeper, 실제 키보드·모니터처럼 자동화할 수 없는 것들이다. `scripts/install.sh`로 설치한 앱으로 확인한다.

### 입력 상태 표시
- [ ] ABC ↔ 한국어 전환 시 막대·메뉴바 카멜레온 색이 즉시 바뀐다
- [ ] 한/영 키를 눌렀지만 전환이 안 된 경우 색도 그대로다
- [ ] 빠르게 여러 번 전환해도 마지막 상태로 끝난다
- [ ] Caps Lock ON → 빨강, OFF → 입력 소스 색으로 돌아온다
- [ ] (다른 입력 소스가 있다면) 일본어·중국어 등에 각자의 기본색이 나온다
- [ ] macOS 입력 소스 표시 숨기기: 켜면 커서 옆 "한 / A" 배지가 이미 열려 있는 앱에서도 바로 사라지고, 끄면 다시 나온다. `defaults read -g TSMLanguageIndicatorEnabled`가 켜면 0, 끄면 "does not exist"다

### 화면
- [ ] 단일 모니터, 내장 + 외부 모니터 모두 막대가 보인다
- [ ] 모니터 연결/해제, 해상도 변경 후에도 제자리에 있다
- [ ] Safari/Chrome 전체 화면, 다른 Space, Mission Control에서 보인다
- [ ] 막대 위를 클릭해도 아래 앱이 클릭된다
- [ ] 상단 배치 시 노치 모델에서 노치 부분만 끊긴다
- [ ] 설정 창을 열었다가 아무것도 바꾸지 않고 닫아도 막대가 그대로 있다. Dock 아이콘을 켠 상태에서 ⌘H로 KeyHue를 가려도, 다른 앱에서 ⌥⌘H(기타 가리기)를 해도 막대가 남는다

### 자동 전환
- [ ] 기본 입력 소스를 삭제·비활성화하면 자동 선택한 입력 소스로 전환하고, 대체 대상도 없으면 현재 입력 소스를 유지한다. 설정에는 사용 불가와 대체 동작 안내가 보이고, 다시 추가하면 저장한 선택이 복구된다
- [ ] 앱·창에서 기억한 입력 소스를 삭제한 뒤 돌아오면 사용 가능한 앱 기록 또는 기본 입력 소스로 대체한다
- [ ] 앱을 바꿀 때 › ABC로 전환: 한국어 상태에서 앱 전환 → ABC, 그대로 두기 → 그대로
- [ ] ESC 옵션 ON: VS Code·터미널·Vim에서 ESC → ABC, 다른 키에는 반응하지 않는다
- [ ] 앱을 바꿀 때 › 복원: Slack 한국어 / Terminal 영문으로 두고 오가면 복원된다. 처음 여는 앱은 ABC
- [ ] 창을 바꿀 때 › ABC로 전환: 터미널 창 1(한글) → 창 2 → ABC. 탭 전환도 확인(터미널·iTerm·VS Code). 대화상자를 열었다 닫아 같은 창으로 돌아오면 그대로다
- [ ] 창을 바꿀 때 › 복원: 터미널 창 1 한글, 창 2 영문으로 두고 오가면 각각 복원된다. ⌘N 새 창은 ABC. 앱도 복원이면 다른 앱에 갔다가 창 1이 앞인 채로 돌아오면 한글. KeyHue를 다시 실행하면 창 기억은 비고 앱 기억으로 복원된다. KeyHue보다 **나중에** 실행한 앱에서도 다른 앱에 다녀오지 않고 바로 창 전환이 동작한다
- [ ] 이전 버전에서 "앱 전환 시 ABC", "앱별 입력 소스 기억"을 켜 둔 상태로 업데이트하면 각각 "ABC로 전환", "복원"으로 선택되어 있다
- [ ] 텍스트 필드 옵션(실험적): 텍스트 필드에서 버튼으로 포커스를 옮기면 ABC
- [ ] 한/영 알림(실험적, ADR 0041): ABC·두벌식이 둘 다 켜져 있을 때만 "실험적 기능 · 한국어 입력" 섹션에 보이고, 켤 때 입력 모니터링 설명이 나온다. 영어·일본어 UI에서도 한국어 입력용 기능임이 드러난다
- [ ] 한/영 알림: 메시지가 사라지는 중(1.6–1.8초)에 다음 단어를 잘못 치면 새 메시지가 또렷하게 보인다. 메시지를 보고 한/영을 바꾸면 메시지가 바로 사라지고 HUD와 겹치지 않는다
- [ ] 한/영 알림·ESC를 켠 채 입력 모니터링 권한을 끄면, 메뉴·설정 창이 권한 필요로 바뀐다. 다시 실행 시 안내에 켜 둔 기능이 모두 나온다
- [ ] 한/영 알림 › 메시지로 알리기를 끄면 막대만 깜빡인다. 막대까지 숨기면 설정 창에 "알림이 보이지 않습니다" 안내가 나온다
- [ ] 다른 언어 알림: ABC에서 `dkssudgktpdy␣` → 화면 아래에 한국어 색 카멜레온과 "안녕하세요?" 메시지가 1.6초 보이고(계속 쳐도 남아 있다), 막대가 한국어 색으로 굵게 3번 깜빡이고 돌아온다. 두벌식에서 `hello␣`(ㅗ디ㅣㅐ) → "hello?"와 ABC 색. 입력한 글자와 입력 소스는 그대로다
- [ ] 다른 언어 알림(치는 중, ADR 0042): ABC에서 `dks`까지 치면 스페이스 전에 "안…?"이 뜨고, 같은 단어를 끝까지 쳐도 다시 뜨지 않는다. 두벌식에서 `he`(ㅗㄷ)까지 치면 "he…?". 터미널에서 `dirname`·`git`을 쳐도 뜨지 않는다
- [ ] 다른 언어 알림: 영어 문장·한글 문장·`ㅋㅋㅋ`·`ㅎㄷㄷ`·지우기로 고친 단어·`didn't`에는 깜빡이지 않는다. 막대를 끄면 메시지만 보인다
- [ ] 다른 언어 알림: 로그 파일에 `wrong language warning: meant hangul`처럼 방향만 남고 단어는 남지 않는다

### 권한
- [ ] 새로 설치: ESC 옵션을 켤 때만 설명 → 시스템 요청이 나온다(앱 시작 시에는 묻지 않는다)
- [ ] 권한 거부 상태: 메뉴에 "–"와 "권한 허용…"이 보이고, 앱 시작 시 "다시 허용…" 안내가 뜬다
- [ ] 같은 서명 키로 다시 빌드·업데이트한 뒤에도 권한이 유지된다

### 설치·배포
- [ ] 릴리즈 zip을 내려받아 첫 실행 시 Gatekeeper 안내대로 "그래도 열기"로 열린다
- [ ] 새로 설치하면 Dock에 없다(메뉴바 전용). 실행할 때도, 다른 앱을 닫을 때도 KeyHue가 포커스를 가져가지 않는다
- [ ] 다시 실행하면 설정 창이 열리고, 열려 있는 동안만 Dock에 보인다(⌘Tab으로 돌아올 수 있다). 창을 닫으면 Dock에서 사라진다
- [ ] Dock에 표시를 켜면 창을 닫아도 Dock에 남는다
- [ ] 앱을 바꾼 직후(0.1초 넘어서) ⌘Space로 직접 바꾼 입력 소스를 KeyHue가 되돌리지 않는다
- [ ] 메뉴에는 막대 모양·색·Dock·로그인 항목이 없고, 설정 창 네 탭(일반·모양·입력 소스·자동 전환)이 보인다. 항목이 많은 자동 전환 탭은 스크롤해 입력기 설치/제거와 권한 안내에 접근할 수 있다
- [ ] 로그인 시 실행 켜기/끄기
- [ ] 언어를 English/한국어/日本語로 바꾸면 메뉴·설정 창이 재시작 없이 바뀐다
- [ ] 표시 언어가 시스템 설정일 때 지원하는 선호 언어가 없으면 영어로 표시된다. 한국어·일본어 지역 태그는 해당 번역을 사용한다

### 통합 입력기 (실험적)
- [ ] KeyHue 하나 설치 후 사용 옵션 ON → 설치·등록·두 모드 활성화 또는 재로그인 안내
- [ ] 메뉴와 설정에서 설치/업데이트/제거, 권한 안내·진행 중 중복 조작 방지
- [ ] 예전 0.0.1 설치본과 같은 버전 개발 재빌드 모두 업데이트, 원래 소스 기본값 보존
- [ ] ⌘Space·Caps Lock·Control Space·Fn·메뉴 각각 전환, 한→영→한 직후 첫 키가 실제 선택 모드와 일치
- [ ] TextEdit·Notes·웹/Electron·Terminal에서 한글/영문 현재 글자만 밑줄, 공백·기호·단축키·Backspace 유실/중복 없음
- [ ] 업데이트/제거 중 다시 선택·종료 실패면 중단, 이전 설치본 보존
- [ ] 제거 후 자신의 서비스만 없어지고 ABC·다른 입력기·KeyHue 설정은 유지, 필요 시 재로그인 후 목록 확인
- [ ] KeyHue 종료 시 기본 입력은 유지되며 자동 연동은 중단

### 성능
- [ ] `Tests/perf/input-latency.sh` 통과 (한/영 반영 200ms 이내)
- [ ] `Tests/perf/ax-timeout.sh` 통과 (멈춘 앱에 대한 AX 요청이 0.5초 안에 끊김)
- [ ] `Tests/perf/app-switch-latency.sh` 통과 (앱 전환 반영 중앙값 100ms 이내, 깜빡임·실패 없음)
- [ ] `Tests/perf/window-switch-after-launch.sh` 통과 (KeyHue보다 늦게 실행된 앱에서도 창 전환 감지)
- [ ] `Tests/perf/input-indicator.sh` 통과 (macOS 입력 소스 표시 숨기기가 실행 중인 앱에 바로 적용, 캡처 확인)
- [ ] 메뉴 **로그 파일 보기** → Finder에서 `KeyHue.log`가 선택된다. 앱·창을 바꾸고 한/영을 바꾼 기록이 시각과 함께 있고, 입력한 글자·창 제목은 없다
- [ ] 활성 상태 보기에서 30분 방치 시 CPU ≈ 0%
- [ ] 빠른 앱 전환·한/영 전환 중 CPU 급증이나 표시 지연이 없다

## 실험 입력기 연동 검증

[ADR 0049](adr/0049-opt-in-input-method-integration.md)의 정책과 연결은 `InputMethodIntegrationTests`/`InputMethodRoutingTests`, 기존 자동 전환 테스트, `SettingsModelTests`에서 검사한다. 가짜 TIS·스케줄러로 기본값 보존, ABC 기억 읽기, 삭제/선택 실패, 권한 상실, 중복·늦은 알림, 입력 시작·문맥 변경 취소, 덮어쓰기 중단을 확인한다. EN/KO/JA 번역도 기존 전체 검증에 포함된다. 실제 시스템 입력 소스를 변경하는 테스트는 아니다.

실제 전환 키·입력 메뉴·빠른 첫 키·문서별 복원·복구 확인 절차는 [입력기 안내](../Resources/InputMethodSpike/README.md#keyhue-유틸리티와-연동-테스트)를 따른다. 현재 정식 릴리즈는 유틸리티만 배포한다. 입력기 설치가 없는 CI에서도 두 옵션 OFF의 기존 동작과 가짜 입력기 후보의 연동 정책을 검증한다.

실제 입력기 수명 주기 회귀 검사는 `InputMethodHostLifecycleTests`이며 기본 비활성이다. 테스트 계정에서 서비스가 설치되지 않고 시스템 입력 소스가 선택된 상태로 실행한다. 다른 소스 보존·두 번 설치/선택/제거·원래 선택 복원을 확인한다. KeyHue는 자동 전환이 개입하지 않도록 종료한 상태여야 한다. 일반 검증과 CI에서는 이 옵션을 켜지 않는다.

```bash
KEYHUE_TEST_HOST_INPUT_METHOD=1 KEYHUE_TEST_APP_PATH=/absolute/path/to/KeyHue.app \
  swift test --filter InputMethodHostLifecycleTests
```

실제 모드 선택/복원까지 검사하려면 조용한 테스트 세션에서 `KEYHUE_TEST_HOST_SELECTION=1`도 명시한다. 일반 실제 수명 주기 검사는 두 모드의 가용성과 제거 잔여 항목을 확인한다.
