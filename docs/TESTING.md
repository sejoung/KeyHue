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

## 자동 테스트

| 종류 | 위치 | 실행 | 무엇을 확인하나 |
|---|---|---|---|
| Core 단위 | `Tests/KeyHueCoreTests` | `swift test` | 입력 소스 색·글리프, 상태 판정, 자동 전환 정책, **자동 전환 조정(지연·덮어쓰기·재시도, 가짜 시간으로 재현)**, 앱별·창별 기억, 권한 판단, 메뉴 상태, 설정 저장(바뀐 값만), 번역 파일 일관성 |
| 앱 통합 | `Tests/KeyHueAppTests` | `swift test` | 실제 화면에 State Bar 패널 생성·위치·속성·색, 실제 입력 소스 조회(TIS), 번역 번들 적용, 설정 창 모델 바인딩, 앱 메뉴 단축키 |
| 스크립트 | `Tests/scripts/test_*.sh` | `Tests/scripts/run.sh` | `release.sh` 전체 시나리오(임시 git 저장소 + 로컬 원격), `signing.sh`(키 파일·클립보드 순서), `release-notes.sh`, `install.sh`, `lint.sh`, `artifacts.sh`(결과 폴더·링크·정리) |
| lint | `scripts/lint.sh` | 〃 | ShellCheck, `$변수` 바로 뒤 한글(bash 3.2 버그) |
| 사이트 | `Tests/site/*.test.js` | `node --test Tests/site/*.test.js` | 데모의 문자 체계 판정, 내부 링크·이미지·앵커, 두 언어 설명서 목차 일치 |
| 릴리즈 서명 경로 | `Tests/ci/release-signing-check.sh` | CI 전용 | 일회용 키로 release.yml과 같은 순서의 서명(임시 키체인 → 해시 서명 → 요구 조건) |
| 한/영 반영 지연 | `Tests/perf/input-latency.sh` | 로컬(실행 중인 KeyHue) | 입력 소스를 실제로 바꾸며 macOS 알림 지연과 KeyHue 반영 지연 비교, 200ms 초과 시 실패 ([ADR 0023](adr/0023-deliver-input-source-notifications-immediately.md)) |
| 멈춘 앱 대기 | `Tests/perf/ax-timeout.sh` | 로컬(터미널에 손쉬운 사용 권한) | 직접 띄운 테스트 앱을 정지시키고 AX 요청 대기 시간을 비교, KeyHue 설정(0.25초)으로 0.5초 안에 끊기지 않으면 실패 ([ADR 0030](adr/0030-bounded-accessibility-requests.md)) |
| 앱 전환 지연 | `Tests/perf/app-switch-latency.sh` | 로컬(실행 중인 KeyHue) | 측정용 앱 두 개를 번갈아 활성화하며 KeyHue가 ABC로 바꾸기까지의 지연·깜빡임을 잼. 실패·깜빡임이 있거나 중앙값 100ms 초과 시 실패. 측정 중에만 "앱을 바꿀 때"를 바꾸고 되돌림. `race` 모드는 KeyHue 없이 시스템 덮어쓰기 재현 ([ADR 0031](adr/0031-faster-app-switch.md)) |
| 실행 직후 창 전환 | `Tests/perf/window-switch-after-launch.sh` | 로컬(실행 중인 KeyHue, 터미널에 손쉬운 사용 권한) | 창 두 개짜리 측정용 앱을 매번 새로 띄우고 곧바로 창을 두 번 바꿔, KeyHue보다 늦게 실행된 앱에서도 창 전환을 감지하는지 확인. 놓친 회차가 있으면 실패. "창을 바꿀 때"가 켜져 있어야 하고, 측정 중에는 화면을 잠그거나 다른 앱을 쓰지 않는다 ([ADR 0033](adr/0033-retry-accessibility-attach-while-launching.md)) |
| macOS 입력 소스 표시 | `Tests/perf/input-indicator.sh` | 로컬(터미널에 화면 기록 권한) | 측정용 앱을 띄운 채 macOS 설정을 표시 → 숨김으로 바꾸며 그 창만 캡처해, 실행 중인 앱에 바로 적용되는지 확인. 캡처는 결과 폴더에 남고, 원래 설정으로 되돌림 ([ADR 0034](adr/0034-hide-macos-input-indicator.md)) |
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

### 자동 전환
- [ ] 앱을 바꿀 때 › ABC로 전환: 한국어 상태에서 앱 전환 → ABC, 그대로 두기 → 그대로
- [ ] ESC 옵션 ON: VS Code·터미널·Vim에서 ESC → ABC, 다른 키에는 반응하지 않는다
- [ ] 앱을 바꿀 때 › 복원: Slack 한국어 / Terminal 영문으로 두고 오가면 복원된다. 처음 여는 앱은 ABC
- [ ] 창을 바꿀 때 › ABC로 전환: 터미널 창 1(한글) → 창 2 → ABC. 탭 전환도 확인(터미널·iTerm·VS Code). 대화상자를 열었다 닫아 같은 창으로 돌아오면 그대로다
- [ ] 창을 바꿀 때 › 복원: 터미널 창 1 한글, 창 2 영문으로 두고 오가면 각각 복원된다. ⌘N 새 창은 ABC. 앱도 복원이면 다른 앱에 갔다가 창 1이 앞인 채로 돌아오면 한글. KeyHue를 다시 실행하면 창 기억은 비고 앱 기억으로 복원된다. KeyHue보다 **나중에** 실행한 앱에서도 다른 앱에 다녀오지 않고 바로 창 전환이 동작한다
- [ ] 이전 버전에서 "앱 전환 시 ABC", "앱별 입력 소스 기억"을 켜 둔 상태로 업데이트하면 각각 "ABC로 전환", "복원"으로 선택되어 있다
- [ ] 텍스트 필드 옵션(실험적): 텍스트 필드에서 버튼으로 포커스를 옮기면 ABC

### 권한
- [ ] 새로 설치: ESC 옵션을 켤 때만 설명 → 시스템 요청이 나온다(앱 시작 시에는 묻지 않는다)
- [ ] 권한 거부 상태: 메뉴에 "–"와 "권한 허용…"이 보이고, 앱 시작 시 "다시 허용…" 안내가 뜬다
- [ ] 같은 서명 키로 다시 빌드·업데이트한 뒤에도 권한이 유지된다

### 설치·배포
- [ ] 릴리즈 zip을 내려받아 첫 실행 시 Gatekeeper 안내대로 "그래도 열기"로 열린다
- [ ] Dock 아이콘 클릭/다시 실행 → 설정 창이 열린다, Dock에 표시 끄기 → 메뉴바 전용
- [ ] 로그인 시 실행 켜기/끄기
- [ ] 언어를 English/한국어/日本語로 바꾸면 메뉴·설정 창이 재시작 없이 바뀐다

### 성능
- [ ] `Tests/perf/input-latency.sh` 통과 (한/영 반영 200ms 이내)
- [ ] `Tests/perf/ax-timeout.sh` 통과 (멈춘 앱에 대한 AX 요청이 0.5초 안에 끊김)
- [ ] `Tests/perf/app-switch-latency.sh` 통과 (앱 전환 반영 중앙값 100ms 이내, 깜빡임·실패 없음)
- [ ] `Tests/perf/window-switch-after-launch.sh` 통과 (KeyHue보다 늦게 실행된 앱에서도 창 전환 감지)
- [ ] `Tests/perf/input-indicator.sh` 통과 (macOS 입력 소스 표시 숨기기가 실행 중인 앱에 바로 적용, 캡처 확인)
- [ ] 활성 상태 보기에서 30분 방치 시 CPU ≈ 0%
- [ ] 빠른 앱 전환·한/영 전환 중 CPU 급증이나 표시 지연이 없다
