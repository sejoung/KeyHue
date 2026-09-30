# 0020. Dock 아이콘을 기본으로 표시하고, 메뉴바 전용 모드는 설정으로 둔다

- 상태: Accepted (명세 §4의 `LSUIElement = YES`와 ADR 0002의 accessory 기본값을 대체, Dock 표시 기본값은 0038에서 다시 끔)
- 날짜: 2026-09-29

## 맥락
명세는 "메뉴바 앱으로 동작하며 Dock에는 표시하지 않는 방향을 우선"했고, `LSUIElement = YES` + `.accessory`로 구현했다. 실제로 써 보니 불편했다.
- 앱을 다시 실행해도(Finder/Launchpad/Spotlight) 아무 반응이 없어서, 실행 중인지 알기 어렵다.
- 노치 때문에 메뉴바 아이콘이 가려지면 설정에 들어갈 방법이 없다.
- Cmd+Tab으로 설정 창에 돌아갈 수 없다.

## 결정
- `Info.plist`에서 `LSUIElement`를 제거한다. 기본은 **일반 앱(`.regular`)으로 Dock에 표시**한다.
- 설정 `showDockIcon`(기본 true)을 둔다. 설정 창 General › Indicators와 메뉴바 메뉴에 **Show in Dock** 토글이 있다.
  - 끄면 `NSApp.setActivationPolicy(.accessory)`로 **재시작 없이** 메뉴바 전용이 된다.
  - 이때 열려 있던 설정 창이 뒤로 숨지 않게 다시 활성화한다.
- `applicationWillFinishLaunching`에서 언어(ADR 0016)와 Dock 정책을 먼저 적용하고 UI를 만든다.
- `applicationShouldHandleReopen`: Dock 아이콘 클릭이나 앱 재실행 시 **설정 창을 연다**.
- 일반 앱은 활성화되면 화면 상단에 앱 메뉴가 필요하므로 `MainMenu`를 둔다.
  - KeyHue: 정보, 설정…(⌘,), 가리기, 종료
  - 편집: 오려두기/복사/붙여넣기/전체 선택
  - 윈도우: 최소화/닫기
  - 모두 번역되고, 언어를 바꾸면 다시 만든다.
- 스크린샷 모드(ADR 0019)는 Dock에 나타나지 않도록 계속 `.accessory`로 실행한다.
- 자동 전환(ADR 0007)은 원래 KeyHue 자신의 활성화를 앱 전환으로 보지 않으므로, Dock 아이콘을 눌러도 입력 소스가 바뀌지 않는다.

## 결과
- 실측
  - 기본 실행 시 `ApplicationType = Foreground`(Dock 표시)
  - 다시 실행하면 프로세스는 하나로 유지되고 설정 창(540×608)이 열린다
  - `showDockIcon = false`면 `UIElement`(메뉴바 전용)
- 메뉴바 전용을 선택한 사용자는 로그인 시 실행 직후 Dock 아이콘이 잠깐 보였다가 사라질 수 있다. `LSUIElement`를 쓰지 않기 때문이다.
- KeyHue가 Cmd+Tab 목록에 나타난다.
