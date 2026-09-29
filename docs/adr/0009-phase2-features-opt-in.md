# 0009. Phase 2 기능은 모두 opt-in으로 함께 제공한다

- 상태: Accepted
- 날짜: 2026-09-29

## 맥락
명세는 MVP와 Phase 2(텍스트 focus 해제 시 ABC, 앱별 Input Source 기억, 전환 HUD, 멀티 모니터 정책)를 구분하고, 특히 Accessibility 기반 text-focus tracking은 MVP에서 제외한다. 이번 작업 범위는 명세의 기능 전체 구현이다.

## 결정
Phase 2 기능도 구현하되, **모두 기본 OFF(멀티 모니터는 기본 All Displays)** 로 두어 MVP의 기본 동작과 원칙을 바꾸지 않는다.

| 기능 | 구현 | 권한 | 기본값 |
|---|---|---|---|
| 전환 HUD | 상태가 바뀔 때 활성 화면 중앙 하단에 `가/a/A`를 0.5초 표시 후 0.15초 fade. 클릭 무시 NSPanel. 앱 시작 직후 초기 상태에서는 표시하지 않음 | 없음 | OFF |
| 멀티 모니터 정책 | All Displays / Active Display Only (ADR 0006) | 없음 | All |
| 앱별 Input Source 기억 | Bundle ID → Source ID를 UserDefaults에 저장(최대 200개, 오래된 것부터 제거). 활성 앱에서 Source가 바뀔 때와 앱을 떠나는 순간 기록. 복원이 ABC 전환보다 우선(ADR 0007). "Forget Remembered Inputs"로 삭제 | 없음 | OFF |
| 텍스트 focus 해제 시 ABC (실험적) | 활성 앱에 `AXObserver`로 `kAXFocusedUIElementChangedNotification` 구독. **텍스트 입력 요소 → 비텍스트 요소**로 이동한 순간에만 전환. role/subrole/`AXEditable`만 읽고 값(`AXValue`)은 읽지 않음 | Accessibility | OFF |

- 앱별 기억에 저장하는 것은 Source ID 문자열뿐이다. 입력 내용·윈도우 제목·URL은 저장하지 않는다.
- Accessibility 권한은 텍스트 focus 옵션을 켤 때만 설명 후 요청한다(ADR 0008과 같은 흐름).
- 텍스트 focus 판정은 `TextInputRole`(AXTextField, AXTextArea, AXComboBox, AXSearchField, AXSecureTextField subrole, AXEditable=true)로 한다.

## 결과
- MVP 사용자는 아무것도 켜지 않으면 명세의 MVP와 동일한 경험을 한다.
- 텍스트 focus 기능은 앱마다 AX 지원 수준이 달라 신뢰도가 낮다. Chrome/Electron 앱은 웹 콘텐츠 AX 트리를 기본으로 노출하지 않아 동작하지 않을 수 있다. 부작용 위험 때문에 `AXEnhancedUserInterface`/`AXManualAccessibility`를 강제로 켜지 않는다. 메뉴에서 "Experimental"로 안내한다.
- "현재 활성 모니터" 판단은 ADR 0006의 제약을 공유한다.
