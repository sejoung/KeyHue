# 0085. 설치한 입력기에서 다운로드 격리 속성을 지운다

상태: Accepted (구현·자동 검증·격리 속성 설치본 실제 확인)

날짜: 2026-10-09

관련: [0017](0017-distribution-developer-id-notarization.md), [0051](0051-single-app-distribution-and-managed-input-method.md), [0084](0084-keep-a-fresh-permission-on-allow-again.md)

## 배경

- 지금까지 입력기 수동 점검은 모두 `scripts/install.sh` 설치본으로 했다. 이 Mac에서 빌드한 앱이라 `com.apple.quarantine`이 없다.
- 브라우저로 받은 zip은 격리 속성이 붙고, 압축을 풀면 KeyHue.app 안의 모든 파일이 물려받는다. 사용자가 "그래도 열기"로 허용하는 것은 바깥 KeyHue.app이다.
- 입력기 설치(`InputMethodManager.install`)는 내장 입력기를 `~/Library/Input Methods`로 복사하는데, 복사가 격리 속성도 그대로 옮긴다.
- 실제 확인(2026-10-09 09:24): 설치본에 다운로드와 같은 격리 속성을 붙이고 입력기를 설치한 뒤 모드를 추가하자, macOS가 "'KeyHueInputMethodSpike.app'을(를) 열 수 없음 … 악성 코드가 없음을 확인할 수 없습니다"를 띄웠다. 입력기는 macOS가 따로 실행하므로 바깥 앱의 허용이 이어지지 않는다. Developer ID 공증이 없는 배포(ADR 0017)에서는 모든 다운로드 사용자가 겪는다.

## 결정

- 입력기를 복사한 직후, 서명 검사(`codesign --verify --deep --strict`) 전에 사본의 모든 파일에서 `com.apple.quarantine`을 지운다(`InputMethodManager.clearQuarantine`).
- 이미 설치된 같은 버전을 다시 설치할 때도 지운다. 이 변경 전에 설치해 막힌 사본을 고치기 위해서다.
- 지우는 것은 KeyHue가 복사한 사본뿐이다. KeyHue.app 안의 원본은 사용자가 받은 그대로 둔다.
- 근거: 사용자는 KeyHue를 열면서 이미 허용했다. 입력기는 같은 앱에 들어 있고 같은 인증서로 서명돼 있으며, 지운 뒤에도 서명을 검사한다.

## 결과

- 내려받은 KeyHue에서 입력기를 설치해도 Gatekeeper 창 없이 모드를 쓸 수 있다.
- 이미 막힌 사용자는 이 버전으로 업데이트한 뒤 **입력기 업데이트 및 사용…**(또는 설치 및 사용…)을 한 번 더 누르면 된다.
- Developer ID로 공증하게 되면 이 처리는 필요 없어진다. 그래도 남겨 두어도 해가 없다.

## 검증

- `InputMethodManagerTests`: 격리된 원본을 설치해도 사본의 폴더·Info.plist·실행 파일에 격리 속성이 없고 원본은 그대로임, 이미 설치된 사본을 다시 설치하면 격리 속성이 지워짐.
- `Tests/scripts/test_install.sh`: `scripts/install.sh --quarantine`이 설치본의 모든 파일(내장 입력기 포함)에 격리 속성을 붙이고 빌드 원본은 건드리지 않음.
- 출시 전 확인 방법: `scripts/uninstall.sh` → `scripts/install.sh --quarantine`. 내려받은 zip을 푼 것과 같은 격리 속성이 붙어, 실제 다운로드 경로를 재현한다.
- 실제 확인(2026-10-09 09:42~): `scripts/install.sh --quarantine` 설치본에서 입력기를 설치하자 `input method quarantine cleared files=25`가 남았고, 사본에는 격리 속성이 없었다(`com.apple.provenance`만 있음). 두 모드를 추가하고 입력할 때 Gatekeeper 창이 뜨지 않았고 한글이 입력됐다.
  - 이 설치본은 Finder로 옮기지 않아 KeyHue가 App Translocation 경로에서 실행됐다. Finder로 옮긴 실제 다운로드와 이 점이 다르다.
  - 시스템 설정 추가 창이 처음 열릴 때 한국어·영어 목록이 비어 있었고, 다른 언어를 눌렀다 돌아오면 보였다. TIS 목록은 정상이라 시스템 설정 표시 문제로 보고, 설치 안내와 매뉴얼에 한 줄을 더했다.
- 출시 전마다 같은 절차를 반복한다: `scripts/install.sh --quarantine` 또는 실제 릴리즈 zip → 그래도 열기 → 입력기 설치 → 모드 추가에서 Gatekeeper 창이 뜨지 않고, `xattr -l ~/Library/Input\ Methods/KeyHueInputMethodSpike.app`에 격리 속성이 없으며, 한글이 입력된다.
