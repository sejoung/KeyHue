# 0002. SwiftPM + AppKit, 앱 번들은 스크립트로 조립한다

- 상태: Accepted — Dock 표시(`LSUIElement`)는 [0020](0020-show-dock-icon-by-default.md)으로 갱신
- 날짜: 2026-09-29

## 맥락
명세는 Swift + AppKit, Swift Package Manager, 외부 의존성 0을 요구한다. 반면 메뉴바 앱으로 동작하려면 `.app` 번들(Info.plist의 `LSUIElement`, 아이콘, 코드 서명)이 필요하고, `SMAppService`·TCC 권한도 번들 식별자를 기준으로 동작한다. SwiftPM은 `.app` 번들을 직접 만들지 못한다.

## 결정
- 소스와 테스트는 **SwiftPM 패키지 하나**로 관리한다(`Package.swift`, swift-tools-version 6.0, Swift 6 언어 모드, macOS 13+).
- Xcode 프로젝트 파일은 두지 않는다. `.app`은 `scripts/build-app.sh`가 조립한다.
  1. `swift build -c release`
  2. `scripts/make-icon.swift`로 `docs/icon.png` → `AppIcon.iconset` → `iconutil`로 `.icns`
     - 원본의 흰 배경을 자동 탐지해 잘라내고 라운드 마스크를 적용, Apple 아이콘 그리드(1024 캔버스/824 본체)에 맞춘다.
  3. `Resources/Info.plist` 템플릿에 버전 치환(`LSUIElement=YES`, `io.github.sejoung.keyhue`)
  4. `codesign` (기본 ad-hoc, `CODESIGN_IDENTITY`로 교체 가능)
- `scripts/verify.sh`는 build → test → bundle을 순서대로 실행하고 로그를 `.artifacts/verify/<timestamp>/`에 남기며 `TestResults` 심볼릭 링크를 갱신한다(.gitignore에 이미 반영된 규칙).
- `main.swift`에서 `setActivationPolicy(.accessory)`를 호출해 `swift run`처럼 번들 없이 실행해도 Dock에 나타나지 않게 한다.
- 생성물(`build/`, `.build/`, `.artifacts/`)은 커밋하지 않는다. 아이콘 원본은 `docs/icon.png` 하나만 둔다.

## 결과
- 저장소가 단순하고 diff 친화적이다. CI에서도 `swift build/test`만으로 검증 가능하다.
- ad-hoc 서명은 빌드마다 서명 해시가 바뀌므로 **재빌드 후 Input Monitoring/Accessibility 권한을 다시 허용**해야 할 수 있다. 배포 시에는 Developer ID 서명 + notarization이 필요하다(현재 범위 밖).
- Xcode의 Asset Catalog, Previews 등은 쓰지 않는다. 설정 UI를 SwiftUI로 크게 만들게 되면 재검토한다.

## 검토한 대안
- **Xcode 프로젝트(.xcodeproj)**: 번들/서명 설정은 편하지만 pbxproj 충돌이 잦고 명세의 SwiftPM 요구와 어긋난다.
- **XcodeGen/Tuist**: 외부 도구 의존이 생긴다.
