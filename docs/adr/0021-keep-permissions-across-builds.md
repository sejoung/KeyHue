# 0021. 모든 빌드를 같은 자체 서명 인증서로 서명해 권한을 유지하고, 끊긴 권한은 앱이 알린다

- 상태: Accepted (ADR 0017의 "릴리즈는 ad-hoc 서명"을 보완)
- 날짜: 2026-09-29

## 맥락
"ESC를 눌러도 전환이 안 된다"는 제보를 확인해 보니, 설정은 켜져 있었지만 로그가 이랬다.

```text
[KeyHue:Keyboard] Input Monitoring not granted; ESC monitor not started
```

- ad-hoc 서명은 빌드마다 cdhash가 바뀌고, designated requirement도 `cdhash H"…"`가 된다.
- TCC(입력 모니터링·손쉬운 사용)는 허용 당시의 요구 조건으로 앱을 식별한다. 그래서 다시 빌드하거나 **업데이트한** KeyHue는 "다른 앱"이 되어 이전 허용이 적용되지 않는다.
- 시스템 설정에는 여전히 켜진 것처럼 보일 수 있어 원인을 알기 어렵다.
- 메뉴의 "–" 표시만으로는 기능이 멈췄다는 사실을 알아채기 어려웠다.

Apple Developer ID가 없어도, 같은 인증서로 서명하면 요구 조건이 `identifier "io.github.sejoung.keyhue" and certificate leaf = H"…"`로 고정된다. 요구 조건 평가는 인증서 신뢰와 무관하므로, 사용자 Mac에 인증서를 설치할 필요가 없다.

## 결정
### 1. 서명 키 하나로 모든 빌드를 서명한다 (`scripts/signing.sh`)
| 명령 | 역할 |
|---|---|
| `create [--replace]` | 자체 서명 코드 서명 인증서 "KeyHue Development"(RSA 2048, 20년) 생성 → `~/.config/keyhue/signing.p12` + `signing.password`(600, 저장소 밖) 보관 → 이 Mac 키체인에 등록 |
| `install` | 보관된 키를 키체인에 등록한다(신뢰 등록·암호 입력 없음). 다른 Mac에서는 두 파일을 복사한 뒤 실행한다 |
| `github` | Repository secrets `KEYHUE_SIGNING_P12`(base64), `KEYHUE_SIGNING_PASSWORD` 등록. `gh`가 있으면 자동, 없으면 값을 클립보드로 하나씩 복사해 안내 |
| `status` | 키 파일, 지문, 키체인 상태 |

- p12는 macOS 기본 LibreSSL로 만든다. OpenSSL 3의 기본 형식은 macOS 키체인이 읽지 못할 수 있기 때문이다. base64 → 디코드 → 임시 키체인 import가 되는 것을 확인했다.
- **인증서를 신뢰로 등록하지 않는다.** codesign은 이름으로 찾으면 신뢰된 인증서만 쓰지만, **SHA-1 해시로 지정하면**(키체인이 검색 목록에 있을 때) 신뢰되지 않은 자체 서명 인증서로도 서명한다. 그래서 `build-app.sh`와 CI는 "KeyHue Development"의 해시를 찾아 해시로 서명한다.
- 신뢰가 없어도 권한 판단에 쓰이는 요구 조건 검사는 동작한다(확인: 신뢰되지 않은 인증서로 서명한 앱이 `codesign --verify -R "=identifier … and certificate leaf = H…"`를 통과하고, 다른 leaf나 `anchor apple generic`은 거부).
- `build-app.sh`는 `CODESIGN_IDENTITY` > "KeyHue Development" > ad-hoc 순으로 서명한다. 보안 타임스탬프는 Developer ID일 때만 붙인다.
- `package.sh`는 서명 결과의 요구 조건을 출력한다. 인증서를 지정했는데 `certificate leaf`가 아니면 실패한다.

### 2. 릴리즈도 같은 키로 서명한다 (`.github/workflows/release.yml`)
- Secrets가 있으면 `scripts/ci-import-signing.sh`가 인증서를 임시 키체인에 설치한다.
  - 코드 서명 권한을 설정하고, 키체인 검색 목록 앞에 둔다.
  - 인증서 SHA-1 해시를 `identity`로 출력하고, 패키징은 그 해시로 서명한다. 신뢰 설정은 하지 않는다.
  - 그다음 "KeyHue Development"로 패키징하고, 작업이 끝나면 키체인을 지운다.
- Secrets가 없으면 경고를 남기고 지금처럼 ad-hoc으로 서명한다.
- 릴리즈 노트는 서명 방식에 따라 권한 안내를 다르게 쓴다(`KEYHUE_SIGNED`).

### 3. 끊긴 권한은 앱이 알린다
- 앱 시작 1초 뒤, ESC 또는 텍스트 필드 전환이 켜져 있는데 권한이 없으면 원인과 선택지(**다시 허용… / 끄기 / 나중에**)를 보여준다.
- "다시 허용"과 메뉴의 "권한 허용…"은 `tccutil reset <ListenEvent|Accessibility> io.github.sejoung.keyhue`로 KeyHue의 이전 항목만 지운 뒤 새로 요청하고 시스템 설정을 연다. 관리자 권한 없이 동작함을 확인했다. 허용된 항목은 지우지 않고, 지운 뒤에는 새 프로세스에서 요청한다([ADR 0084](0084-keep-a-fresh-permission-on-allow-again.md)).
- 새 권한을 먼저 묻지 않는다는 원칙(ADR 0008)은 유지한다. 이미 켜 둔 기능이 멈췄을 때만 알린다.
- 진단 로그를 남긴다: ESC 모니터 시작/권한 없음, tap 비활성화, ESC keyDown, 전환 결과. ESC가 아닌 키는 기록하지 않는다.

### 4. 키 보호
- 키 파일은 저장소 밖(`~/.config/keyhue`, 700/600)에 두고, `.gitignore`에 `*.p12`, `*.pem`, `*.key`, `*.keychain-db`, `signing.password`, `.env` 등을 추가해 실수로 커밋하는 것을 막는다.
- 키를 가진 사람은 KeyHue인 척 서명할 수 있고, 사용자가 KeyHue에 허용한 권한을 이어받을 수 있다. 그래서 GitHub Secrets와 비밀번호 관리자 외에는 두지 않는다.

## 결과
- 확인: 같은 인증서로 두 번 빌드하면 cdhash는 달라도 요구 조건은 같다. ad-hoc은 빌드마다 `cdhash`가 바뀐다.
- 키를 등록한 뒤의 릴리즈부터는 업데이트해도 권한이 유지된다. ad-hoc 릴리즈에서 처음 넘어올 때 한 번은 다시 허용해야 한다(앱이 안내).
- 키를 잃어버리고 새로 만들면 모든 사용자가 한 번 다시 허용해야 한다. 키 파일은 비밀번호 관리자 등에 백업한다.
- Gatekeeper의 첫 실행 차단은 그대로다. 이것은 Developer ID와 공증이 있어야 없어진다(ADR 0017).
- **실패에서 배운 점**: 처음에는 CI에서 인증서를 관리자 도메인에 신뢰로 등록하려 했다(`sudo security authorizationdb write com.apple.trust-settings.admin allow` + `add-trusted-cert -d`). macOS 15 러너에서 `NO (-60005)`(errAuthorizationDenied)로 실패해 v0.1.3 릴리즈가 게시되지 않았다. 해시로 서명하면 신뢰가 필요 없어 이 단계를 없앴다.
- CI 흐름(임시 키체인 import → 해시 서명 → 요구 조건 확인 → 패키징 → 정리 후 키체인 검색 목록 복원)은 테스트 키로 로컬에서 그대로 재현해 확인했다. GitHub 러너에서의 첫 성공은 다음 릴리즈에서 확인한다.

## 보완 (2026-10-03): 기존 키 파일 권한
- umask는 새로 만드는 파일에만 적용돼, 다른 Mac에서 복사해 둔 `signing.password`·`signing.p12`가 남에게 읽히는 권한 그대로 쓰일 수 있었다. 키를 만들 때 두 파일을 항상 600으로 맞춘다.
- 테스트: `test_generate_makes_a_stale_password_file_private`. CI 키체인 가져오기(`scripts/ci-import-signing.sh`)는 가짜 `security`로 `Tests/scripts/test_ci_signing.sh`에서 검사한다.
