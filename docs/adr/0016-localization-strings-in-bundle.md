# 0016. UI 번역은 번들의 .lproj/Localizable.strings로 하고, 앱 안에서 언어를 고를 수 있게 한다

- 상태: Accepted (ADR 0010의 "메뉴는 영어 고정"을 대체)
- 날짜: 2026-09-29

## 맥락
글로벌 출시를 위해 메뉴, 설정 창, 권한 안내 alert를 OS 언어에 맞춰야 한다. 이 프로젝트는 SwiftPM으로 빌드하고 `.app`은 스크립트로 조립한다(ADR 0002). SwiftPM 리소스(`Bundle.module`)는 조립한 `.app`에서 번들 위치가 맞지 않아 쓰기 어렵다(ADR 0011과 같은 이유).

## 결정
- `Resources/<lang>.lproj/Localizable.strings`(en, ko, ja)를 두고, `scripts/build-app.sh`가 `Contents/Resources/`로 복사한다. Info.plist에 `CFBundleLocalizations`를 선언한다.
- 코드에서는 `L("English text")`(= `NSLocalizedString`, `Bundle.main`)만 쓴다. SwiftUI에도 `Text(L(...))`처럼 같은 함수를 쓴다. 이렇게 하면 추출 경로가 하나라서 테스트로 검사할 수 있다.
- **키는 영어 원문**으로 한다. 번역 파일이 없는 환경(`swift run`)에서도 영어로 자연스럽게 표시된다.
- 여러 문단짜리 alert는 문단별로 키를 나누고 코드에서 이어 붙인다.
- 입력 소스 이름(예: "두벌식", "2-Set Korean")은 번역하지 않는다. macOS가 OS 언어로 준다.
- **앱 언어 선택**: 한국어 OS에서도 영어 UI를 원하는 사용자가 있으므로, 설정 창 General 탭에 Language(System Default / English / 한국어 / 日本語)를 둔다.
  - `KeyHueSettings.appLanguage`(기본 `system`, 기본값은 저장하지 않음 — ADR 0014)
  - `L()`은 `Localization.bundle`에서 찾는다. `system`이면 `Bundle.main`(OS 언어 우선순위), 아니면 해당 `.lproj` 번들이다. 번들은 lock으로 보호해 어느 스레드에서도 `L()`을 부를 수 있다.
  - **재시작 없이 바로 적용한다.** 메뉴는 `buildMenu()`로 다시 만들고, 설정 창(SwiftUI)은 settings 변경으로 다시 그려진다.
  - 앱 전역의 `AppleLanguages`는 건드리지 않는다. 그래서 macOS가 그리는 일부 텍스트(About 패널의 "Version", 색상 패널, 입력 소스 이름)는 OS 언어를 따른다. 설정 창에 이 점을 안내한다.
  - 언어 목록은 각 언어 이름을 그 언어로 쓴다(English/한국어/日本語). 사용자가 읽지 못하는 언어로 바꿔 버렸을 때도 되돌릴 수 있게 하기 위해서다.
- `LocalizationTests`가 다음을 검사한다.
  - 코드의 모든 `L("…")` 키와 색상 프리셋 이름이 세 언어 파일에 모두 있는지
  - 세 언어 파일의 키 집합이 같은지
  - `%@` 개수가 번역에서도 같은지
  - 코드에서 쓰지 않는 키가 남아 있지 않은지
  - 선택 가능한 언어(`AppLanguage`)마다 `.lproj`와 `CFBundleLocalizations` 항목이 있는지

## 결과
- 문자열을 추가하거나 바꾸면 세 언어 파일을 함께 고쳐야 테스트가 통과한다.
- String Catalog(.xcstrings)는 Xcode 빌드가 필요해 쓰지 않았다. Xcode 프로젝트로 옮기게 되면 재검토한다.
- 언어를 추가하려면 `.lproj` 하나, `CFBundleLocalizations`, `AppLanguage` case만 늘리면 된다. 번역 품질(특히 일본어)은 원어민 검토가 필요하다.
