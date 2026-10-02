# IMK 기술 검증 기록 — T단계

> 이전 단계 기록(0046~0050). 현재 배포·버전·설치·영문 조합은 [ADR 0051](adr/0051-single-app-distribution-and-managed-input-method.md)과 [현재 안내](../Resources/InputMethodSpike/README.md)를 따른다. 아래 별도 빌드/ZIP·버전·영문 단어 버퍼는 당시 실험 기록이며 현재 사용 절차가 아니다.

> 2026-10-02: 실험 코드와 공통 파이프라인 구현, 자동 검증 완료. **등록·실제 앱 호환성·T단계 전체 완료는 아직 확인하지 않았다.** 구조는 [ADR 0045](adr/0045-experimental-input-method-component.md), 스크립트 결정은 [ADR 0046](adr/0046-shared-component-build-and-imk-spike.md)를 따른다.

## 구현한 실험

| 항목 | 현재 상태 |
|---|---|
| 별도 IMK 서버/프로세스 | 시작 코드·두 모드 메타데이터 구현, 실제 등록 후 실행 미확인 |
| Swift 6 / Objective-C 클래스 | 빌드 및 번들 실행 파일의 클래스/콜백 셀렉터 self-check 통과 |
| 한글 조합 | 마지막 글자만 marked text 유지, 앞 글자 확정·받침 이동·조합 중 키 취소의 순수 로직 테스트 통과 |
| 입력 소스 아이콘·이름 | 투명한 가/A 메뉴 아이콘, 설정용 카멜레온·가/A 배지와 한국어/영어 입력기 이름, 리소스·메타데이터 검사 |
| 영문 버퍼 | 즉시 확정/단어 marked text의 두 후보 구현, 세션 메뉴에서 비교 가능 |
| 모드 | 명시적인 IMK 모드 값과 활성화 시 TIS ID를 확인하는 코드, 실제 전달 순서 미확인 |
| 고침·교체·되돌리기 | 미구현, 클라이언트 API 관찰 후 추가 실험 필요 |
| 설치·업데이트·제거 | 명시적인 설치/등록 요청 스크립트와 실패 복구 구현, 실제 IMK 설치/등록·제거 절차 미확인 |

실험 타깃은 `KeyHueInputMethodSpikeCore`, `KeyHueInputMethodSpike`이고 코드 위치는 `Tools/InputMethodSpike/`다. 정식 `KeyHueInputMethodCore`/`KeyHueInputMethodApp`의 구현으로 표시하지 않는다. 기존 `KeyHueApp`을 참조하지 않으며 판정 모델·고침 옵션을 포함하지 않는다.

사용자 실험에서 한글 밑줄이 단어 전체로 이어지고 입력 소스 아이콘이 흰 네모로 보인다는 피드백을 받았다. [ADR 0048](adr/0048-current-syllable-composition-and-input-mode-icons.md)에 따라 한글은 마지막 글자만 조합하고, 메뉴는 앱 아이콘 대신 투명한 가/A 이미지를 사용한다. 영문 단어 조합 실험만 64타 상한을 유지한다. Latin 버퍼 최종 선택과 앱별 확정·선택 영역 동작은 0단계 전에 검증한다. 콜백이 메인 스레드 외부에서 실행되면 오류 분류를 남기고 키를 전달하며, 비동기 재전송은 하지 않는다. 이를 발견하면 조합 처리 문맥을 재설계해야 한다.

## 현재 공통 명령

[ADR 0051](adr/0051-single-app-distribution-and-managed-input-method.md)과 [ADR 0052](adr/0052-input-method-activation-and-single-app-scripts.md)에 따라 배포·설치는 KeyHue 하나로 통합했다. 아래 자동 검증의 초기 구성 요소 분리 기록은 당시 결과이며 현재 명령 계약이 아니다.

| 작업 | 단일 앱 명령 |
|---|---|
| 빌드 | `scripts/build-app.sh` |
| 번들 검사 | `scripts/check-bundle.sh` |
| universal ZIP | `scripts/package.sh` |
| Developer ID 서명·공증 경로 | `scripts/notarize.sh` |
| 버전 파일/override | 루트 `VERSION` / 환경 변수 `VERSION` |
| 로컬 설치 | `scripts/install.sh` 또는 `scripts/install.sh --no-build` |
| 입력기 설치·업데이트·제거 | KeyHue 설정/메뉴의 입력기 관리 |

`scripts/app-config.sh`가 제품 메타데이터를 공유한다. `CONFIG`, `UNIVERSAL`, `BUILD_NUMBER`, `CODESIGN_IDENTITY`는 환경 변수다. `verify.sh`는 부모 앱과 내장 서비스·세션 코어를 검증한다. 구성 요소 인자는 거부하며 별도 입력기 ZIP·등록 헬퍼는 제거했다. 빌드와 self-check는 입력 소스를 설치·등록·선택하지 않는다. 실제 Developer ID 공증 실행은 별도 검증이다.

설치·복구·수동 체크는 [입력기 안내](../Resources/InputMethodSpike/README.md)를 따른다.

## 자동 검증 결과

환경: macOS 26.6.2 (25G83), arm64, Apple Swift 6.4, Xcode의 macOS 27 SDK. 최소 대상은 macOS 13이며 실제 macOS 13 호환성은 별도 검증이다.

2026-10-02 `scripts/verify.sh` 결과:

- 기존 Core 258개, App 81개, 실험 Core 7개 테스트 통과
- 스크립트 43개 통과: 구성 요소 버전/작업 폴더 분리, 잘못된 대상·번들 거부, 두 ZIP/최신 유틸리티/릴리즈 노트 보존 포함
- 사이트 16개 통과
- 두 로컬 번들의 ID·버전·리소스·서명 검사 통과
- IMK 클래스/콜백 셀렉터 self-check 통과
- 변수 뒤 한글 lint 통과. 첫 전체 검증에서는 ShellCheck가 없어 건너뛰었고, 이후 공식 ShellCheck 0.11.0을 임시 디렉터리에서 실행해 필수 lint를 통과했다. lint 수정 후 구성 요소 스크립트 테스트 5개도 다시 통과

로그: `.artifacts/verify/20261002-111337/` (추가 lint는 `lint-shellcheck.log`). 실제 IMK 컨트롤러와 클라이언트 간 편집을 이 단위 테스트로 검증했다고 해석하지 않는다.

두 `package.sh` 명령도 실행해 arm64/x86_64 universal 실행 파일과 고정 개발 인증서 서명을 확인했다. `build/dist/KeyHue-0.2.5.zip`·`KeyHue.zip`과 `KeyHueInputMethodSpike-0.0.1.zip`·각 SHA-256 파일이 함께 남는다. 실험을 패키징한 뒤 최신 유틸리티 ZIP의 SHA-256도 유틸리티 배포 ZIP과 일치한다. 이 결과는 Developer ID 공증이나 입력 소스 등록 성공을 의미하지 않는다.

ADR 0047의 설치 스크립트 추가 후 전체 검증을 다시 실행했다(`.artifacts/verify/20261002-115433/`). Swift 346개, 스크립트 53개(설치 14개), 사이트 16개, 필수 ShellCheck, 설치 헬퍼 Swift 6 컴파일, 두 번들·self-check가 통과했다. lint 자체 테스트는 외부의 필수 ShellCheck 설정을 분리해 의도한 가짜 도구 조건으로 검사한다.

샌드박스 밖에서 설치 헬퍼의 실제 TIS 선택 상태 조회도 확인했다. 실제 사용자 입력기 폴더의 설치·등록·전환은 실행하지 않았으며, 설치 테스트의 TIS 등록·프로세스 종료·시스템 설정 실행은 모두 대체 도구를 사용했다. 실제 등록·재로그인·입력 호환성은 아래 표에 남아 있다.

ADR 0048 반영 후 전체 검증도 통과했다(`.artifacts/verify/20261002-124703/`): Swift 350개(실험 세션 11개), 스크립트 54개, 사이트 16개, 필수 ShellCheck, 두 번들·서명·self-check. 세션 테스트는 306개 결정적 입력 표본의 한 글자 조합과 확정 문자열 보존을 검사했다. 별도 이미지 검사에서 네 TIFF의 투명도·글리프 존재·16pt 크기·1x/2x 표현을 확인하고, 밝은/어두운 배경의 확대 미리보기(`input-method-icons-preview.png`)를 확인했다. 이는 macOS 입력 소스 메뉴 자체의 표시 검증이 아니며, 수정 후 재설치·실제 입력 확인은 남아 있다.

수정본 재설치 뒤에도 상단 메뉴바가 흰 네모라는 사용자 피드백을 받아 실제 설치본과 등록 정보를 읽기 전용으로 확인했다. 설치된 `HangulTemplate.tiff`/`LatinTemplate.tiff`가 존재하고 TIS의 `kTISPropertyIconImageURL`이 그 파일을 가리켰다. `Bundle.image(forResource:)`로 두 이미지가 template·16pt·2개 표현으로 읽히는 것도 확인했다. 기존 `TextInputMenuAgent`에 TERM을 보내자 macOS가 새 프로세스를 실행했고, 입력기 프로세스 PID는 유지됐다. 사용자가 메뉴바의 `가` 표시로 변경됐다고 확인했다. 이 환경에서는 메뉴 표시 프로세스에 이전 이미지가 남은 것으로 판단한다. 임의의 아이콘 재생성·입력 소스 변경·시스템 캐시 삭제는 하지 않았다. 반복 확인 절차는 [번들 안내](../Resources/InputMethodSpike/README.md)에 남겼다.

입력 소스 추가 화면에서도 구분이 필요하다는 후속 피드백으로 설정용 카멜레온 PNG와 32pt 가/A palette 배지, 입력기 부모 이름 번역을 추가했다. 전체 검증 `.artifacts/verify/20261002-130738/`에서 Swift 350개·스크립트 56개·사이트 16개·필수 ShellCheck·두 번들·서명·self-check가 통과했다. 설정용 이미지 세 개는 `Bundle.image(forResource:)`로 일반 이미지로 읽혔고, 가/A 배지의 1x/2x·투명 모서리·글리프도 검사했다. 밝은/어두운 배경의 이미지 미리보기(`settings-icons-preview.png`)를 확인했으며 메뉴용 template 설정도 유지됐다. 이 추가 수정본은 실제 사용자 폴더에 설치하지 않았고, 입력 소스 추가 화면 자체의 반영은 남아 있다.

## 수동 검증표

사용자는 모드 전환 후 실제 입력을 시도했고, 위 두 표시 문제를 보고했다. 해당 앱·환경·설치 절차와 수정 후 결과는 아직 기록되지 않았다. 아래 호환성 항목은 별도 검증이 필요하다. 테스트 계정에서 재현한 뒤 OS·앱 버전·모드·버퍼 정책·결과와 재현 절차를 적는다. 실제 입력 기록을 자동 수집하지 않는다.

| 검사 | 결과 |
|---|---|
| 첫 설치·모드 추가·재로그인 필요 여부·Gatekeeper | 미확인 |
| 수정 후 마지막 글자 밑줄·가/A 메뉴 아이콘·라이트/다크 표시 | 한글 메뉴 아이콘 `가`는 메뉴 프로세스 재시작 후 사용자 확인. 밑줄·A·라이트/다크 전환은 별도 미확인 |
| 입력 소스 추가 화면의 카멜레온·가/A 배지·번역된 입력기 이름 | 리소스/메타데이터 구현, 재설치 후 실제 설정 화면 반영은 미확인 |
| 모드 선택/TIS ID·언어·알림·IMK callback 순서/스레드 | 미확인 |
| TextEdit·Notes 기본 입력, 조합·Backspace·기호·경계 | 미확인 |
| Safari/Chrome 입력 필드, 선택 덮어쓰기·자동 완성 | 미확인 |
| VS Code·Terminal 기본 입력·단축키 | 미확인 |
| 앱·필드·창 이동, 조합 확정 요청·다른 세션 분리 | 미확인 |
| 유틸리티 종료 상태의 입력, 실행 상태의 색·자동 전환·복원 | 미확인 |
| 범위 교체·공백·모드 변경·즉시 되돌리기 실험 | 미구현/미확인 |
| 교체·재시작·제거·시스템 ABC로 복구 | 미확인 |
| 입력 지연·메모리·버퍼 정책 비교와 성능 목표 | 미확인 |

이 표와 [설계의 T단계 체크리스트](INPUT_METHOD_DESIGN.md#8-단계와-완료-기준)를 채운 뒤, 영문 버퍼·교체 순서·모드/수명 주기 계약을 후속 ADR로 확정한다.

## 유틸리티 연동 (ADR 0049)

[ADR 0049](adr/0049-opt-in-input-method-integration.md)에 따라 기본값·복원 대상의 ABC → KeyHue 영문 해석, 별도 opt-in 두 모드 유지, 연동 OFF 후 ABC 복귀를 구현했다. 두 모드 유지의 입력 모니터링 권한·직접 ABC 선택의 재연결·빠른 첫 키 한계와 실제 전환 체크 표는 [번들 안내](../Resources/InputMethodSpike/README.md#keyhue-유틸리티와-연동-테스트)에 있다. 시스템 단축키를 변경하거나 입력을 다시 쓰지 않는다.

이 단락의 구현은 실제 ⌘Space/Caps Lock/Fn 전환 성공이나 T단계 완료의 증거가 아니다. 실제 앱·입력 이벤트·문서 복원의 경쟁과 입력 유실/중복 여부는 사용자 테스트 결과를 받은 뒤 기록한다.

ADR 0049 반영 후 전체 검증 `.artifacts/verify/20261002-135228/` 통과: Swift 372개(Core 279, App 82, 실험 세션 11), 스크립트 56개, 사이트 16개, 필수 ShellCheck, 설치 헬퍼 컴파일, 두 로컬 번들의 서명·메타데이터 검사와 IMK self-check. 자동 검증은 실제 입력 소스를 선택하거나 시스템에 수정본을 설치하지 않았다. 테스트용 번들은 `build/KeyHue.app`과 `build/KeyHueInputMethodSpike.app`에 있으며, 유틸리티의 새 옵션은 설치 후 사용자가 켠다.

## 모드 콜백 누락의 키 시점 보정 (ADR 0050)

한글→영문→한글 이후 한글 표시인데 영문이 입력된다는 사용자 보고를 받았다. 실제 상태 로그에서 유틸리티의 소스 연결 성공과 대응하는 IMK 모드 콜백이 없는 전환을 확인했고, TIS 읽기 전용 조회에서 한글 선택 상태를 확인했다. [ADR 0050](adr/0050-synchronize-imk-mode-before-key-events.md)에 따라 매 키 전에 선택 모드를 동기화하고 같은 모드 콜백의 조합 확정을 막았다. 이 수정의 실제 앱 결과는 입력기 재설치 후 확인한다. 로그 읽기·자동 검증 중 실제 입력 소스나 설치본을 변경하지 않았다.

ADR 0050 반영 후 전체 검증 `.artifacts/verify/20261002-141759/` 통과: Swift 377개(Core 279, App 82, 실험 세션 16), 스크립트 56개, 사이트 16개, 필수 ShellCheck, 두 번들·서명·IMK self-check. 모드 콜백 없이 돌아오는 첫 키와 반복 콜백의 조합 보존을 순수 테스트로 확인했다. 수정된 입력기는 `build/KeyHueInputMethodSpike.app`에 준비했으며, 설치본 교체·실제 앱에서의 입력 성공은 아직 확인하지 않았다.

## KeyHue 통합 배포·앱 설치 관리·영문 현재 글자 조합 (ADR 0051)

사용자가 입력기 단독 설치의 사용성 문제를 제기해 [ADR 0051](adr/0051-single-app-distribution-and-managed-input-method.md)로 배포 결정을 갱신했다. 공개 빌드·ZIP은 KeyHue 하나이며 서명된 IMK 서비스를 `Contents/Helpers`에 내장한다. 사용 옵션 ON 또는 설치/업데이트 버튼이 사용자 폴더 복사·등록·두 모드 활성화와 연동 준비를 수행한다. 제거는 ABC로 복귀한 뒤 자신의 설치본/모드만 정리한다. 같은 버전 개발 재빌드도 업데이트를 표시한다. 영문은 이전 글자를 확정하고 현재 한 글자만 조합하며 단어 전체 조합 메뉴를 제거했다.

전체 검증 `.artifacts/verify/20261002-151843/` 통과: Swift 390개(Core 279, App 94, 실험 세션 17), 스크립트 59개, 사이트 16개, 필수 ShellCheck, 설치 헬퍼 컴파일, 통합 앱과 내장 서비스 메타데이터·버전·서명·IMK self-check. 활성화 실패 복구와 미존재/미신뢰 원본 검사를 추가한 최종 Swift 테스트는 **392개(Core 279, App 96, 세션 17)** 통과했다. 설치/제거 테스트는 임시 폴더와 가짜 OS 어댑터만 사용하며 사용자 입력 소스·실행 중 입력기를 변경하지 않았다.

통합 `package.sh`도 실행해 부모/서비스 모두 0.2.5·빌드 58, arm64+x86_64, 고정 개발 인증서 서명을 확인했다. ZIP의 최상위 앱은 `KeyHue.app` 하나이고 내장 서비스는 부모 서명의 nested code로 봉인됐다. KeyHue 설정 UI 한·영 스크린샷과 웹 매뉴얼을 갱신했다. Developer ID 공증과 실제 설치/제거·모드 전환·앱별 조합 표시는 이 자동 결과에 포함하지 않는다. 테스트용 앱은 `build/KeyHue.app`이고 사용자 절차는 [현재 안내](../Resources/InputMethodSpike/README.md)를 따른다.

## 통합 앱 재설치와 스크립트 정리 검증 (2026-10-02)

[ADR 0052](adr/0052-input-method-activation-and-single-app-scripts.md)에 따라 구성 요소별 공개 인자·설치 헬퍼·별도 앱/ZIP 생성 경로를 제거했다. 현재 명령은 이 문서의 단일 앱 표를 따른다. 이전 초기 검증의 구성 요소 분리 결과는 역사 기록이다.

실제 사용자 환경에서는 등록/활성화 API가 성공해도 한글이 비활성으로 남았다. 사용자는 시스템 설정에서 한글·영문을 직접 추가할 수 있다고 확인했고, 이후 읽기 전용 TIS 조회에서 부모·한글·영문 모두 enabled=1, 두 모드는 selectable=1이었다. 이는 직접 추가 경로의 확인이며 자동 활성화 수정의 성공 증거로 사용하지 않는다. 설치 완료 후 비활성인 상태는 재로그인 필수가 아니라 직접 추가 대기로 안내한다. 사용 요청을 유지하고 가용성이 바뀌면 연동을 다시 평가한다.

전체 `scripts/verify.sh` 통과: `.artifacts/verify/20261002-163601/`. Swift 398개(Core 279 + App 102 + 실험 Core 17), 스크립트 51개, 사이트 16개, ShellCheck, 통합 번들 메타데이터·중첩 서명·IMK self-check를 확인했다. 추가 회귀 검사는 제거 후 재설치, API 성공 후 비활성, 부모 활성화 후 모드 노출·새 핸들, 직접 추가 후 옵션 유지, 감시 폴더 밖의 임시 사본, 단일 앱 설치 복구·ZIP·대상 인자 거부다. 실제 편집 앱의 입력 호환성은 계속 수동 검증 대상으로 남긴다.

## 입력 소스 잔여 항목과 재설치 검증 (ADR 0053)

macOS 26.6.2에서 API 성공과 실제 멤버십이 불일치하고, 두 모드가 enabled여도 부모가 disabled인 경우를 확인했다. 기본 활성 메타데이터를 false로 바꾸고 자기 항목만 보완하면 새 프로세스 조회에서 두 모드 활성/비활성과 제거 후 0개를 확인할 수 있었다. 기존 프로세스의 현재 소스는 이전 값으로 남았다. 설치·제거 후 KeyHue만 자동 재시작하고, 작업 전 ABC 복귀·선택 안전 확인은 새 프로세스에서 수행한다.

전체 검증: `.artifacts/verify/20261002-175104/` — Core 279, App 111(실제 환경 검사는 기본 제외), 실험 Core 17, 스크립트 52, 사이트 16 및 번들·서명·self-check 통과. 실제 설치 위치의 두 번 설치/제거/재설치·두 selectable 모드·설정 항목 제거·다른 소스 보존 검사는 `.artifacts/input-method-lifecycle/20261002-175402/membership-cycle.log`에서 통과했다.

선택 실험에서는 새 프로세스가 한글·영문을 실제 선택하는 것을 확인했지만 기존 프로세스는 이전 소스를 계속 읽었다. 후속 반복의 영문 선택 한 건은 유지되지 않아 선택·타이핑 호환성 완료로 표시하지 않는다(`selection-attempt.log`). 사용자 입력/앱·문서 포커스 변경이 가능한 환경의 자동 선택 검사는 별도 옵션으로 분리했다. 실제 사용의 빠른 전환·첫 키·밑줄·삭제는 수정 설치본으로 수동 검증한다.

## 자동 활성화 중단 (2026-10-03, ADR 0055)

macOS 26.6.2에서 TIS 활성화 API는 두 모드에 대해 성공을 반환하고도 반영되지 않았고, KeyHue의 `com.apple.inputsources`/`AppleEnabledThirdPartyInputSources` 쓰기는 cfprefsd가 거부했다. [ADR 0055](adr/0055-users-add-input-sources-manually.md)에 따라 KeyHue는 설치·서명 확인·등록만 하고 부모·두 모드 활성화와 입력 소스 목록 편집을 하지 않는다. 사용자가 시스템 설정에서 두 모드를 추가하면 연동이 시작되고, 제거 전에도 사용자가 두 모드를 먼저 제거한다. 위의 ADR 0052·0053 자동 활성화·멤버십 보완 기록은 역사 기록이다.
