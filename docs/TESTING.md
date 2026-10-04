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

- 종류마다 최근 20회만 남긴다(`ARTIFACTS_KEEP`로 바꿀 수 있다. 1보다 작거나 숫자가 아니면 1로 보며, 이번 실행 폴더는 항상 남는다). 이전 실행과 비교하려면 `<종류>/` 아래 시각 폴더를 연다.
- 새 스크립트는 `source scripts/artifacts.sh` 뒤 `OUT="$(artifacts_dir perf/<이름>)"`으로 폴더를 받아 결과를 남긴다.
- KeyHue가 관여하는 성능 점검은 테스트하는 동안 쌓인 KeyHue 로그 파일 부분을 `keyhue-file.log`로 함께 남긴다(`keyhue_log_mark`/`keyhue_log_save`).

## 문제가 생겼을 때 로그 보기

KeyHue는 원인을 좇는 데 필요한 이벤트를 남긴다([ADR 0036](adr/0036-diagnostic-log.md)). 다시 재현하지 않아도 지난 기록을 볼 수 있다.

```bash
open -R ~/Library/Logs/KeyHue/KeyHue.log                                   # 메뉴 "로그 파일 보기"와 같다
/usr/bin/log show --last 1h --predicate 'subsystem == "KeyHue"' --style compact   # 통합 로그(notice 이상)
/usr/bin/log stream --predicate 'subsystem == "KeyHue"' --level debug --style compact  # 세부 사항까지 실시간
```

- 실행할 때마다 버전, macOS, 기본값과 다른 설정, 권한, 맨 앞 앱을 남긴다. 형식이 깨진 설정 값을 기본값으로 대신했으면 `settings: ignored corrupt values for <키>`도 남긴다(값은 남기지 않는다). 실행 직후에는 KeyHue 자신이 맨 앞인 경우가 많고, 그때는 다음 앱 활성화부터 관찰한다.
- 흐름의 예: `app activated` → `not ready … will retry` → `attached` → `window switched within …` → `auto reset: switched select(…) ok` → `caps=… source=…`. 앱 전환 대기 중 단축키·클릭으로 직접 바꿨으면 `auto reset: kept manual switch made while the app switch settled`가 남는다(ADR 0037).

## 자동 테스트

기본 `scripts/verify.sh`는 입력기 코어·앱 통합·설치 실패 복구·서명된 앱 번들을 검사한다. 사용자 입력 소스나 임시 입력 창을 변경하는 host 검사는 선택형이다.

| 종류 | 위치 | 실행 | 무엇을 확인하나 |
|---|---|---|---|
| Core 단위 | `Tests/KeyHueCoreTests` | `swift test` | 입력 소스 색·글리프, 두벌식 조합·오타 언어 판정(다 지운 단어 재판정·전환 단축키·Caps Lock 경계, KeyHue 모드), 상태 판정, 자동 전환 정책, **자동 전환 조정(지연·덮어쓰기·재시도·창 전환 대기 세대·대기 중 수동 전환, 가짜 시간으로 재현)**, 앱별(가장 오래 안 쓴 앱부터 정리)·창별 기억, 입력기 연동의 기억·기본값 짝 해석, 권한 판단, 메뉴 상태(기본 입력 소스 하위 메뉴·체크 표시), 설정 저장(바뀐 값만, 깨진 값은 그 키만 기본값)·색 hex, 로그 파일 회전, 화면 좌표, 릴리즈 버전 비교·업데이트 확인 간격, 번역 파일 일관성 |
| IMK 실험 Core | `Tests/KeyHueInputMethodSpikeCoreTests` | `swift test` | 마지막 글자 조합/키 취소, 받침 이동·겹모음/겹받침, 결정적 표본의 클라이언트 편집 결과 보존, 한 번 확정, 모드·세션 분리, 영문 현재 한 글자 조합·여러 단어 원문 보존·Backspace·실제 모드 동기화, 조합 단계별 Backspace·모드 전환 경계, 입력기 세션 확인 알림의 모드 ID(ADR 0062), 끄기·수동·자동 고침 정책(ADR 0064) |
| 앱 번들 | `scripts/check-bundle.sh` | `scripts/verify.sh` | 통합 KeyHue와 내장 서비스의 ID·실행 파일·버전·중첩 서명·리소스·Info.plist·IMK 콜백 self-check |
| 앱 통합 | `Tests/KeyHueAppTests` | `swift test` | 입력기 설치/교체/실패 복구·선택 상태 경합·중복 설치 잠금·외부 번들/링크 거부·내장 원본과 설치 위치 겹침 거부·입력 소스 목록 무변경(등록만)·사용자 모드가 남은 제거 거부, macOS 26 입력 소스 항목 읽기·손상 스키마 거부, 준비 상태 128개 조합·진단 JSON 손상·실행 파일 없음·비정상 종료·시간 초과 종료·큰 출력·출력을 쥔 자식 프로세스, 내부 작업 인자 해석(`WorkerCommand`)·로그 파일 기록 조건, 권한 흐름(가짜 `PermissionGate`), 입력기 메뉴 상태와 설정 창·메뉴 일치, 설정 모델·상태 메뉴 제목·업데이트 확인·한/영 경고 감시의 엣지 케이스(`AppEdge*`) |
| 스크립트 | `Tests/scripts/test_*.sh` | `Tests/scripts/run.sh` | `release.sh` 전체 시나리오(임시 git 저장소 + 로컬 원격, 0으로 시작하는 버전·버전 인자 둘 이상 거부), `signing.sh`(키 파일 권한·클립보드 순서), `ci-import-signing.sh`(가짜 `security`로 임시 키체인·검색 목록 복원), `release-notes.sh`, `install.sh`의 내장 앱 검증·복사 실패 복구·공백 경로, `test_bundle.sh`의 단일 앱 ZIP·버전/빌드/아이콘·구성 요소 인자 거부·번들 메타데이터 손상·빌드/패키징/공증 사전 검사, `lint.sh`, `artifacts.sh`(결과 폴더·링크·정리, `ARTIFACTS_KEEP` 하한) |
| lint | `scripts/lint.sh` | 〃 | ShellCheck, `$변수` 바로 뒤 한글(bash 3.2 버그) |
| 사이트 | `Tests/site/*.test.js` | `node --test Tests/site/*.test.js` | 데모의 문자 체계 판정(장음 부호 ー 등 여러 문자 공통 글자), 내부 링크·이미지·앵커·id 중복, 두 언어 설명서 목차·소제목·스크린샷 일치와 상호 링크, 이미지 대체 텍스트·비율, 외부 링크·다운로드 파일 이름 |
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
- [ ] 여러 모니터에 창이 있는 한 앱(터미널·브라우저)에서 다른 모니터의 창을 클릭하고 바로 한/영을 바꾸면 전환 HUD·한/영 경고 메시지가 그 창의 모니터에 뜨고, "활성 모니터에만 표시"의 막대도 그 모니터로 옮겨 간다(ADR 0063)
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
- [ ] 한/영 알림(실험적, ADR 0041): ABC·두벌식(또는 KeyHue 입력기 두 모드)이 둘 다 켜져 있을 때만 "실험적 기능 · 한국어 입력" 섹션에 보이고, 켤 때 입력 모니터링 설명이 나온다. 영어·일본어 UI에서도 한국어 입력용 기능임이 드러난다
- [ ] 한/영 알림: 메시지가 사라지는 중(1.6–1.8초)에 다음 단어를 잘못 치면 새 메시지가 또렷하게 보인다. 메시지를 보고 한/영을 바꾸면 메시지가 바로 사라지고 HUD와 겹치지 않는다
- [ ] 한/영 알림·ESC를 켠 채 입력 모니터링 권한을 끄면, 메뉴·설정 창이 권한 필요로 바뀐다. 다시 실행 시 안내에 켜 둔 기능이 모두 나온다
- [ ] 한/영 알림 › 메시지로 알리기를 끄면 막대만 깜빡인다. 막대까지 숨기면 설정 창에 "알림이 보이지 않습니다" 안내가 나온다
- [ ] 다른 언어 알림: ABC에서 `dkssudgktpdy␣` → 화면 아래에 한국어 색 카멜레온과 "안녕하세요?" 메시지가 1.6초 보이고(계속 쳐도 남아 있다), 막대가 한국어 색으로 굵게 3번 깜빡이고 돌아온다. 두벌식에서 `hello␣`(ㅗ디ㅣㅐ) → "hello?"와 ABC 색. 입력한 글자와 입력 소스는 그대로다
- [ ] 다른 언어 알림(치는 중, ADR 0042): ABC에서 `dks`까지 치면 스페이스 전에 "안…?"이 뜨고, 같은 단어를 끝까지 쳐도 다시 뜨지 않는다. 두벌식에서 `he`(ㅗㄷ)까지 치면 "he…?". 터미널에서 `dirname`·`git`을 쳐도 뜨지 않는다
- [ ] 다른 언어 알림: 영어 문장·한글 문장·`ㅋㅋㅋ`·`ㅎㄷㄷ`·지우기로 고친 단어·`didn't`에는 깜빡이지 않는다. 막대를 끄면 메시지만 보인다
- [ ] 다른 언어 알림: ABC에서 `dks`로 알림을 본 뒤 단어를 처음까지 지우고 다시 `dks`를 치면 또 알린다. 단어 처음에서 ⌘Space로 바꾸고 친 단어도 판정한다
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
- [ ] KeyHue 하나 설치 후 사용 옵션 ON → 설치·등록 후 시스템 설정에서 두 모드 추가 안내(KeyHue는 입력 소스 목록을 바꾸지 않음), 두 모드를 추가하면 옵션을 다시 켜지 않아도 연동 시작·한글 선택
- [ ] 메뉴와 설정에서 설치/업데이트/제거, 권한 안내·진행 중 중복 조작 방지
- [ ] 예전 0.0.1 설치본과 같은 버전 개발 재빌드 모두 업데이트, 원래 소스 기본값 보존
- [ ] ⌘Space·Caps Lock·Control Space·Fn·메뉴 각각 전환, 한→영→한 직후 첫 키가 실제 선택 모드와 일치
- [ ] TextEdit·Notes·웹/Electron·Terminal에서 한글/영문 현재 글자만 밑줄, 공백·기호·단축키·Backspace 유실/중복 없음
- [ ] 업데이트/제거 중 다시 선택·종료 실패면 중단, 이전 설치본 보존
- [ ] 두 모드가 시스템 설정에 남아 있으면 제거 시 모드 제거 안내 오류·파일 유지. 두 모드를 제거한 뒤 제거하면 자신의 서비스만 없어지고 ABC·다른 입력기·입력 소스 설정·KeyHue 설정은 유지, 필요 시 재로그인 후 목록 확인
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

[ADR 0049](adr/0049-opt-in-input-method-integration.md)의 정책과 연결은 `InputMethodIntegrationTests`/`InputMethodSourceMappingTests`/`InputMethodDefaultAvailabilityTests`/`InputMethodRoutingTests`, 기존 자동 전환 테스트, `SettingsModelTests`·`InputMethodMenuStateTests`에서 검사한다. 가짜 TIS·스케줄러로 기본값 보존, ABC·시스템 두벌식 기억과 기본값의 짝 해석(연동 OFF면 KeyHue 모드를 시스템 소스로), 사용 불가 안내, 삭제/선택 실패, 권한 상실, 중복·늦은 알림, 입력 시작·문맥 변경 취소, 덮어쓰기 중단을 확인한다. EN/KO/JA 번역도 기존 전체 검증에 포함된다. 실제 시스템 입력 소스를 변경하는 테스트는 아니다.

실제 전환 키·입력 메뉴·빠른 첫 키·문서별 복원·복구 확인 절차는 [입력기 안내](../Resources/InputMethodSpike/README.md#keyhue-유틸리티와-연동-테스트)를 따른다. 현재 정식 릴리즈는 유틸리티만 배포한다. 입력기 설치가 없는 CI에서도 두 옵션 OFF의 기존 동작과 가짜 입력기 후보의 연동 정책을 검증한다.

실제 입력기 수명 주기 회귀 검사는 `InputMethodHostLifecycleTests`이며 기본 비활성이다. 테스트 계정에서 서비스가 설치되지 않고 KeyHue 모드도 추가되지 않은 상태, 시스템 입력 소스가 선택된 상태로 실행한다. 두 번 설치/제거해도 입력 소스 목록이 바뀌지 않는지, 등록 카탈로그와 원래 선택 복원을 확인한다. KeyHue는 자동 전환이 개입하지 않도록 종료한 상태여야 한다. 일반 검증과 CI에서는 이 옵션을 켜지 않는다.

```bash
KEYHUE_TEST_HOST_INPUT_METHOD=1 KEYHUE_TEST_APP_PATH=/absolute/path/to/KeyHue.app \
  swift test --filter InputMethodHostLifecycleTests
```

두 모드를 시스템 설정에서 추가한 설치본을 새 빌드로 갱신한 뒤 재사용 버튼이 등록·재복사를 반복하지 않는지 검사하려면 `KEYHUE_TEST_HOST_UPDATE=1`을 지정한다. 실제 모드 선택/복원은 아래 IMK 클라이언트 검사가 맡는다.

실제 IMK 텍스트 입력은 별도 Cocoa 앱의 NSTextView로 검사한다. 조합 중에 ←·→·Return·Tab·⌘→·클릭이 와도 마지막 글자가 남는지도 확인한다([ADR 0050](adr/0050-synchronize-imk-mode-before-key-events.md) 보완). 화면 잠금을 해제하고 두 KeyHue mode가 이미 설치된 상태로 실행한다. 임시 창에만 테스트 이벤트를 보내며 시작할 때 선택된 입력 소스를 확인하고 복원한다.

```bash
KEYHUE_TEST_HOST_E2E=1 KEYHUE_TEST_APP_PATH=/absolute/path/to/KeyHue.app \
  bash Tests/host/input-method-e2e.sh
swift Tests/host/input-source-settings.swift  # 편집 목록의 실제 두 KeyHue mode 확인
```

runner는 자동 모드 연결의 간섭을 피하기 위해 실행 중인 KeyHue 유틸리티를 잠시 종료하고 모든 종료 경로에서 원래 입력 소스와 유틸리티 실행 상태를 복원한다. 검사 중 임시 창을 그대로 두어야 한다. 선택 확인은 해당 텍스트 입력 context를 기준으로 하고 첫 키·한영 왕복도 검사한다. 원래 입력 소스와 설정 목록 보존은 종료 후 새 worker의 조회로 확인한다.

[ADR 0056](adr/0056-isolated-correction-and-undo-probe.md)과 [ADR 0057](adr/0057-automatic-correction-observation-and-input-priority.md)의 교체·자동 확인 실험은 수정된 서비스를 설치한 뒤 전용 앱 ID로 실행한다. 일반 앱 고침 옵션이나 언어 판정기의 평가가 아니다.

```bash
KEYHUE_TEST_HOST_E2E=1 KEYHUE_TEST_CORRECTION_PROBE=1 \
  KEYHUE_TEST_APP_PATH=/absolute/path/to/KeyHue.app \
  bash Tests/host/input-method-e2e.sh
```

`dkssud`의 Space 교체/한글 모드, 즉시 Backspace 원문/영문 복원, 다음 Space 재고침 억제, 일반 삭제, 이모지·결합 문자 앞 UTF-16 범위, 방향키 이동 후 이력 무효화와 정상 영어·식별자 보존을 검사한다. 순수 `CorrectionProbeTests`는 모드 요청 실패·교체 거부·원문 복구·외부 편집·세션 불일치·재진입도 검사한다. 실제 앱 완료 여부는 [호환성 표](INPUT_METHOD_COMPATIBILITY.md)에 별도로 기록한다.

관찰한 IMK callback에서는 편집 요청 뒤에도 이전 범위가 반환됐다. 입력기는 메인 큐에서 새 상태를 자동 관찰하며 150ms 기한 뒤에는 검증 가능한 자기 편집만 복구하고 종료한다. 이 기한은 동기 RPC의 응답 시간 제한이 아니다. F13은 제거했으며 기본·고침 검사의 키는 `NSTextView.keyDown`으로 한 번만 전달한다. 입력기 문자 키 뒤에는 실제 한 글자 조합이 존재하는지도 확인한다. `handleEvent`와 `keyDown`을 함께 호출해 경계 이벤트를 중복 전달하지 않는다.

대기 없는 다음 키 burst 세 번, 즉시 Backspace와 되돌리기 중 다음 키, 관찰 전 커서 이동·외부 편집, 실제 범위 교체 거부 뒤 원문/공백 보존과 후속 입력도 검사한다. **2026-10-03 격리된 자동 고침·되돌리기와 경합 검사가 통과했으며, 일반 앱/판정기 검증으로 확대하지 않는다.** 두 실제 필드 사이 이동 중 고침 취소, 왕복 후 되돌리기 이력 폐기, 대기 중 ABC·KeyHue 한글 직접 선택과 첫 키 보존도 검사한다(ADR 0058). 임의 앱의 포커스·빠른 외부 모드 왕복과 실제 모드 거부 복구는 별도 검사 대상이다. 기존 설치본을 실제로 업데이트하는 수명 주기 검사까지 묶으려면 `KEYHUE_TEST_UPDATE_SERVICE=1`을 추가한다. 이 옵션은 설치 파일을 변경하므로 일반 CI에서 켜지 않는다. 고침 검사 전에는 입력기 실행 파일이 지정한 packaged 앱의 payload와 같은지도 확인한다.

결과는 `.artifacts/input-method-e2e/<시각>/`에 전후 상태 JSON, 단계마다 저장한 `client.log`, `client-stdout.log`와 `client-stderr.log`로 남는다. 60초 watchdog으로 테스트 앱이 종료된 경우 마지막 acceptance가 없으면 실패이며 runner가 원래 환경을 복원한다. 앱 로그는 `~/Library/Logs/KeyHue/KeyHue.log`, IMK 서버 로그는 `~/Library/Logs/KeyHue/KeyHueInputMethod.log`에서 확인한다. 두 제품 로그는 입력 글자와 키 코드를 기록하지 않는다.


[ADR 0064](adr/0064-correction-modes-off-manual-automatic.md)의 수동 고침 신호 실험은 `KEYHUE_TEST_MANUAL_PROBE=1`로 실행한다. 별도 테스트 앱 ID(`…testclient.manual-probe`)에서 실제 판정기로 영문 단어(`dkssudgktpdy`, `gksrmf`) 직후의 한글 전환을 네 경로로 시험한다: 앱 안 선택, 다른 프로세스 worker, 설정된 이전 입력 소스 단축키, 입력 메뉴. 단어 고침, 되돌리기(모드 유지), 대조군(`hello`, `keyboard`, 새 짧은 단어, 커서 이동), 문장의 두 번째 단어 결과를 `RESULT:` 줄로 남긴다. HID 단축키와 메뉴는 셸 runner가 요청 파일을 받아 실행하며 테스트 앱이 앞에 있을 때만 보낸다. 서버의 결정·결과·생략 이유 로그(단어 없음)는 `manual-probe-server.log`에 남는다. 실행 중 다른 앱을 쓰면 포커스 확인에서 중단된다.

```bash
KEYHUE_TEST_HOST_E2E=1 KEYHUE_TEST_MANUAL_PROBE=1 \
  KEYHUE_TEST_APP_PATH=/absolute/path/to/KeyHue.app \
  bash Tests/host/input-method-e2e.sh
```

### TextEdit 실제 키 입력 검사

[ADR 0058](adr/0058-external-mode-callbacks-and-native-editor-acceptance.md)·[ADR 0059](adr/0059-finalize-composition-on-input-source-change.md)의 검사는 별도 opt-in이다. 화면이 잠금 해제된 상태에서 검사 동안 임시 문서의 포커스를 유지한다. 실제 입력 메뉴 전환 때문에 두 문서를 모두 검사하면 약 3분, 문서 종류를 나누면 각 약 2분이 걸린다. 기존 Accessibility·이벤트 전송 권한이 필요하며 runner는 권한을 요청하거나 재설정하지 않는다. 먼저 위 업데이트 검사로 packaged 앱과 설치된 서비스 실행 파일을 맞춘다.

```bash
KEYHUE_TEST_TEXTEDIT=1 KEYHUE_TEST_APP_PATH=/absolute/path/to/KeyHue.app \
  bash Tests/host/textedit-input-method-e2e.sh
```

`KEYHUE_TEST_TEXTEDIT_KIND=plain` 또는 `rich`를 추가하면 해당 문서 종류의 기본 사례와 같은 창 조합/두 창 왕복을 검사한다(기본값 `both`). `KEYHUE_TEST_TEXTEDIT_WINDOWS_ONLY=1`은 문서 종류별 기본 사례를 생략하고 같은 창의 미확정 조합·창 왕복만 검사한다. 일반 텍스트·서식 있는 텍스트의 새 파일 두 개만 Launch Services로 연다. 실제 입력 메뉴로 ABC·KeyHue 두 모드를 선택하며, Swift helper는 매 키 직전에 TextEdit PID와 고유한 `AXFocusedWindow` 제목을 확인한 뒤 HID 경로에 키 한 쌍을 보낸다. 전면 앱이나 창이 달라지면 즉시 중단한다. AppleScript `key code` 결과만으로 IMK 처리 경로가 검증됐다고 판단하지 않는다.

조합·공백·삭제·겹받침·방향키·Return/Tab·한영 왕복·선택 덮어쓰기와 문서 왕복 후 첫 키를 검사한다. 같은 창에서 `안`을 조합한 뒤 영문 전환·`a + Space`가 `안a `로 이어지는지도 확인한다. 기본 사례의 문자열 불일치는 모아 마지막에 실패시킨다. 같은 창 조합의 시작 조건 또는 보존이 실패하면 잔여 조합이 다음 사례에 영향을 주지 않도록 즉시 중단한다. 포커스·키 전달 오류도 즉시 종료한다.

`KEYHUE_TEST_TEXTEDIT_MODE_SWITCH=worker`는 전환 경로를 별도 프로세스의 TIS 선택으로 바꾼다(기본 `menu`). 같은 창/창 왕복의 초기 조합 준비와 문서 초기화는 기본적으로 입력 메뉴를 사용해 이미 조합 중인 context에서 떠나는 경로를 분리한다. `KEYHUE_TEST_TEXTEDIT_PREPARE_MODE=worker`는 이 준비도 worker로 바꿔 진입부터 재현한다. `KEYHUE_TEST_TEXTEDIT_EXIT_SOURCE=abc`는 이탈 대상을 ABC로 바꾼다(기본 `latin`, KeyHue 영문). 키 직전 source ID 조회 성공과 실제 문서 context 준비는 구분한다. 모든 경로는 로그에 기록한다. 일반 앱 자동 고침은 허용하지 않는다. 테스트 문서의 결과만 읽고 사용자 문서 내용은 읽지 않는다.

```bash
KEYHUE_TEST_TEXTEDIT=1 KEYHUE_TEST_TEXTEDIT_WINDOWS_ONLY=1 \
  KEYHUE_TEST_TEXTEDIT_MODE_SWITCH=worker KEYHUE_TEST_TEXTEDIT_EXIT_SOURCE=abc \
  KEYHUE_TEST_APP_PATH=/absolute/path/to/KeyHue.app \
  bash Tests/host/textedit-input-method-e2e.sh
```

결과와 OS·서비스 메타데이터, 키 직전 source ID, 전후 상태 JSON, 해당 실행 구간의 `input-method-server.log`는 `.artifacts/input-method-textedit/<시각>/`에 남는다. 서버의 확정 로그만으로 반환값 없는 편집 API의 실제 성공을 판단하지 않고 클라이언트 문자열도 확인한다. watchdog은 문서 종류별 180초·같은 창/창 왕복만 120초·두 종류 전체 300초를 부여하고 자기 테스트 프로세스만 종료한다. 성공·실패 후 생성한 문서만 저장 없이 닫고 원래 선택·KeyHue 실행 상태를 복원하고 전후 KeyHue configured IDs를 비교한다. 일반 CI에서 실행하지 않으며, 실패한 사례도 [호환성 기록](INPUT_METHOD_COMPATIBILITY.md)에 남긴다.

### 진입 첫 키와 새 서버 검사

[ADR 0060](adr/0060-input-method-entry-and-cold-start-acceptance.md)의 `KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY=1`은 일반 텍스트 임시 문서에서 첫 `d → ㅇ`, `ks → 안`, 영문/ABC 전환과 `a + Space → 안a `를 세 번 검사한다. 창 왕복 전용 옵션과 함께 사용할 수 없다. 첫 키나 조합이 실패하면 뒤 사례를 중단하고 원시 `d`로 전달됐는지 여부만 추가 기록한다. 문서를 다시 포커스하거나 전환을 재시도해 실패를 복구하지 않는다.

`KEYHUE_TEST_TEXTEDIT_COLD_START=1`을 추가하면 매 회 실제 메뉴로 한글/ABC 준비를 마친 뒤 ABC 상태에서 자기 설치 경로·bundle ID의 입력기만 정상 종료한다. 종료와 PID를 확인한 뒤 전환·첫 키를 검사한다. 강제 종료·입력 소스 목록 편집은 하지 않는다. 새 서버의 초기화와 callback은 `input-method-server.log`에서 확인한다. 새 계정·재로그인·최초 설치·TSM 전체 초기화의 대체 검사가 아니다. 전환 뒤 100ms와 키별 helper 지연이 있어 지연 없는 첫 키·성능 기준도 별도 검사다.

```bash
KEYHUE_TEST_TEXTEDIT=1 KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY=1 \
  KEYHUE_TEST_TEXTEDIT_COLD_START=1 KEYHUE_TEST_TEXTEDIT_MODE_SWITCH=shortcut \
  KEYHUE_TEST_APP_PATH=/absolute/path/to/KeyHue.app \
  bash Tests/host/textedit-input-method-e2e.sh
```

진입 전용 검사의 `MODE_SWITCH`는 `menu`(기본), `worker`, `shortcut`, `app`, `repair`를 받는다. `repair`는 KeyHue 모드를 `--keyhue-select-input-source-repairing` worker로 선택해 앱과 같은 입력기 세션 복구를 실행하고 결과 이름(`acknowledged`·`repaired`·`unrepaired`·`skipped`)을 `client.log`에 남긴다([ADR 0062](adr/0062-repair-input-method-session-with-previous-source-shortcut.md)). 복구는 설정된 이전 입력 소스 단축키를 누르므로 그 단축키가 켜져 있어야 하며 설정은 바꾸지 않는다. `shortcut`은 설정된 이전 입력 소스 단축키(시스템 항목 60)의 활성화·key code·수식 키를 읽어 실제 누르기·떼기 이벤트를 보내고 목표 소스를 확인한다. 메뉴로 한글/ABC의 이전 소스 쌍을 명시적으로 준비하며 설정을 바꾸지 않는다. 해당 단축키가 비활성이거나 지원하지 않는 형태, 목표 소스로 전환되지 않으면 실패한다. 현재 확인한 `⌘Space` 결과를 다른 키의 검증으로 사용하지 않는다.

`app`은 전용 비활성 AppKit 선택 앱 하나를 실행해 계속 같은 PID의 메인 run loop에서 TIS 요청을 처리한다. `source-sender-0.log`와 순번별 결과에 PID·목표·상태를 남기고 첫 키는 별도 확인한다. 매 요청마다 새 앱을 띄우지 않는다. 해당 PID와 정확한 실행 경로를 확인해 자기 앱을 종료한 다음 원래 선택·유틸리티 상태를 복원한다. 이 비교 앱의 통과는 실제 KeyHue 유틸리티 자동 연동 전체의 완료 증거가 아니다.

`KEYHUE_TEST_TEXTEDIT_FRESH_CLIENT=1`은 진입 전용·새 서버 검사와 함께 쓴다([ADR 0061](adr/0061-external-selection-does-not-open-input-method-session.md)). TextEdit이 실행 중이면 거부하며 사용자의 TextEdit을 종료하지 않는다. ABC를 선택한 뒤 runner가 TextEdit을 새로 띄우고 메뉴 준비 없이 한 번만 검사한다. 서비스가 실행 중이면 같은 조건으로 정상 종료하고 없으면 그대로 진행한다.

```bash
KEYHUE_TEST_TEXTEDIT=1 KEYHUE_TEST_TEXTEDIT_ENTRY_ONLY=1 KEYHUE_TEST_TEXTEDIT_COLD_START=1 \
  KEYHUE_TEST_TEXTEDIT_FRESH_CLIENT=1 KEYHUE_TEST_TEXTEDIT_MODE_SWITCH=app \
  KEYHUE_TEST_APP_PATH=/absolute/path/to/KeyHue.app \
  bash Tests/host/textedit-input-method-e2e.sh
```

진입 검사는 첫 키 직전 서비스 프로세스 유무와 PID를 `client.log`에 남긴다. 판정은 문서 문자열로 하며 메뉴 경로는 이 시점에 서비스가 없어도 통과한다. 서버 로그는 클라이언트가 끝날 때까지의 `input-method-server.log`와 원래 소스 복원 구간의 `input-method-cleanup.log`로 나뉜다. 복원 callback을 테스트 결과로 읽지 않는다.

진입 검사의 watchdog은 180초다. 현재 메뉴·설정된 `⌘Space`의 새 서버 검사는 통과했지만 worker·AppKit 프로그램 전환의 콜드 첫 키 실패는 남아 있다. 외부 선택은 세션 없는 클라이언트에 입력기 세션을 만들지 않으므로 이 실패는 현재 알려진 제약이다. `worker`의 기동 상태 통과만으로 이 실패를 덮지 않는다. 원래 상태 복원과 미지원 경로의 실패도 [호환성 표](INPUT_METHOD_COMPATIBILITY.md)에 기록한다. 기본 CI에서 실행하지 않는다.
