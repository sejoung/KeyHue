# 0015. 입력 소스별 설정을 위해 SwiftUI 설정 창을 둔다

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
입력 소스별 색(ADR 0013)을 메뉴만으로 설정하면 "입력 소스 N개 × 프리셋 11개" 서브메뉴가 되어 쓰기 어렵다. 명세는 "설정 화면은 필요하면 SwiftUI를 사용할 수 있다"고 허용한다.

## 결정
- 메뉴에 **Settings… (⌘,)** 를 추가하고, `NSWindow` + `NSHostingController`로 SwiftUI 설정 창을 띄운다. 창은 처음 열 때 만들고 닫아도 재사용한다.
- 탭 3개로 나눈다.
  - **General**: State Bar(표시/위치/두께/불투명도/디스플레이), 메뉴바 아이콘 색, HUD, Launch at Login
  - **Input Sources**: 켜진 입력 소스별 `ColorPicker`(지정한 색은 Reset 가능), Caps Lock 색, 전체 초기화, 기본 입력 소스, 감지 한계 안내
  - **Automation**: 앱 전환/ESC/앱별 기억/텍스트 필드(실험적). 권한이 없으면 경고와 "Grant Access…" 버튼을 보여준다
- `SettingsModel`(ObservableObject)이 `SettingsStore`를 감싼다. 모든 변경은 `SettingsStore.update`를 거치므로 메뉴와 설정 창이 항상 같은 상태를 본다.
- 입력 소스 목록은 창을 열 때와 `kTISNotifyEnabledKeyboardInputSourcesChanged` 알림을 받을 때 다시 읽는다.
- 메뉴는 기존 항목을 유지하고, Colors 서브메뉴는 열 때마다 켜진 입력 소스 기준으로 다시 만든다. 자주 쓰는 조작은 메뉴에서, 세부 설정은 창에서 한다.
- macOS 13 지원을 유지하려고 `@Observable`(14+) 대신 `ObservableObject`를 쓴다.

## 결과
- 오프스크린 렌더링으로 en/ko/ja 세 언어에서 세 탭의 레이아웃을 확인했다.
- 메뉴바 앱(`LSUIElement`)이라 창을 열 때 `NSApp.activate`로 앞으로 가져온다.
- 설정 창 코드는 AppKit/SwiftUI에 묶여 있어 단위 테스트 대상이 아니다. 로직은 `KeyHueSettings`/`SettingsStore`(테스트 대상)에 둔다.
