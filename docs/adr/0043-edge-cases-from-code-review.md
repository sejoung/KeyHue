# 0043. 전체 코드 검토에서 찾은 엣지 케이스를 테스트로 고정하고 고친다

- 상태: Accepted
- 날짜: 2026-10-01

## 맥락
한/영 경고(ADR 0040–0042)를 붙인 뒤 전체 코드를 세 영역으로 나눠 검토했다.
- 판정 로직(Core Mistype)
- 앱 연결(키보드 감시, 경고 표시, 설정)
- 기존 코드(자동 전환, 기억, 로그, 화면)

찾은 것은 하나씩 **먼저 실패하는 테스트로 재현한 뒤** 고쳤다. 재현할 수 없는 것(실제 이벤트 탭 등)은 코드 경로를 확인하고 고친 뒤 수동 체크리스트에 남겼다.

## 결정

### 판정 로직 (ADR 0041, 0042 보완)
| 문제 | 수정 | 테스트 |
|---|---|---|
| 단어 중간에 Caps Lock(지원하지 않는 상태)이 끼면 뒤 글자를 새 단어로 판정했다 | 그 단어를 버린다(`discard`). 단어가 비어 있을 때만 처음부터 | `capsLockInsideWordDropsTheWholeWord` |
| 단어 끝 직후 지우기(공백 삭제 → 앞 단어와 이어짐)를 무시해, 이어 친 조각을 판정했다 | 지우기는 언제나 다음 단어 경계까지 판정하지 않는다 | `backspaceRightAfterBoundaryDropsTheNextWord` |
| 한글 모드의 웃음·울음 표현(ㅜㅠ, ㅡㅜ, ㅜㅡㅜ, ㅠㅠㅋㅋ, ㅋ큐ㅠ)을 영어로 판정했다 | ㅋ ㅎ ㅠ ㅜ ㅡ 낱자와 그로 생긴 받침 없는 음절(큐 쿠 크 휴 후 흐)만으로 된 것은 표현으로 본다 | `koreanEmoticonsAreNotEnglish` (10가지) |
| 치는 중 판정에서 받침 없는 ㅗ·ㅜ·ㅡ 음절(고)을 "바뀌지 않음"으로 봤다. 다음 키에 과가 된다 | 그런 마지막 음절은 빼고 본다. 받침이 있으면 모음은 그대로다 | `stableTextExcludesAVowelThatCanStillCombine` |
| 모델 파일이 CRLF이면(git autocrlf) 읽지 못해 기능이 조용히 꺼졌다 | 줄바꿈을 모두 받는다 | `modelParserAcceptsCRLFAndRejectsBrokenFiles` |
| 모델 파일에 같은 줄이 두 번이면 합계가 어긋났다 | 깨진 파일로 보고 읽지 않는다 | 같은 테스트 |
| 모델 파일의 합이 Int를 넘으면 앱이 멈췄다(테스트 프로세스 중단으로 확인) | 깨진 파일로 보고 읽지 않는다 | 같은 테스트 |
| 모델 파일에 음수 값이 있었다 | 깨진 파일로 보고 읽지 않는다 | 같은 테스트 |

### 앱 연결 (ADR 0041)
| 문제 | 수정 | 테스트 |
|---|---|---|
| HUD를 끈 뒤 경고 메시지가 낡은 화면(빠진 모니터일 수도)에 떴다. 활성 화면을 HUD·활성 모니터 표시일 때만 구했기 때문이다 | `followsActiveScreen`에 경고 메시지를 넣는다. 따라가지 않을 때는 값을 비운다. 모니터를 꽂거나 빼면 다시 구한다 | `activeScreenIsFollowedOnlyWhenSomethingUsesIt` |
| 메시지가 사라지는 중에 새 경고가 오면, 진행 중인 페이드 아웃이 새 메시지를 투명하게 만들었다 | HUD와 같이 0초 애니메이션으로 덮는다 | 실제 시간이 필요해 수동 확인 |
| 경고를 보고 입력 소스를 바꾸면 전환 HUD가 메시지 위에 겹쳤다 | 입력 소스가 바뀌면 메시지를 바로 숨긴다 | `toastHidesAtOnceWhenTheUserReacts` |
| 실행할 때 권한 안내가 ESC 기능만 말하는데 "끄기"는 한/영 경고까지 껐다 | 켜 둔 기능을 모두 이름으로 보여 준다 | 수동 확인 |
| 모델을 읽지 못해도 설정 창에 "동작 중"으로 보였다 | 설정 창에 안내를 띄운다 | `missingModelIsShownInSettings` |
| 실행 중에 입력 모니터링 권한을 거둬 가도 "동작 중"으로 보였다(ESC 포함) | 상태를 볼 때 권한을 다시 확인하고, 없으면 감시를 멈춘다 | 실제 이벤트 탭이 필요해 수동 확인 |

### 기존 코드
| 문제 | 수정 | 테스트 |
|---|---|---|
| 응답 없는 앱 안내(ADR 0038)가 한 번도 뜨지 않았다. 메뉴·설정 창을 열 때 같은 앱에 다시 붙으면서 표시를 지웠고, 멈춘 앱에 몇 초씩 다시 매달렸다 | 붙기를 포기한 앱에는 다른 앱에 갔다 올 때까지 다시 붙지 않는다(`needsAttach`) | `stalledAppIsNotRetriedOnEveryMenuOpen` 외 2개 |
| 앱이 40 ms 안에 또 바뀌면(A→B→C), 이전 앱의 입력 소스를 B의 기억으로 덮어썼다. B의 예약된 전환도 C가 앞일 때 실행됐다 | 대기 중인 활성화는 세대 번호로 취소한다. 전환이 일어나지 않은 앱 몫으로는 기록하지 않는다 | `appFrontForLessThanTheSettleDelayKeepsItsMemory` |
| 뒤에 있던 앱의 다른 창을 눌러 활성화하면, 40 ms 대기 중에 온 창 변경이 이전 앱의 입력 소스를 새 앱 창에 기록했다. 늦게 실행된 창 전환이 앱 기억 복원도 덮었다 | 대기 중의 창 변경은 앱 전환의 일부로 보고 따로 기록·전환하지 않는다. 앱 전환이 그때의 앞 창으로 판단한다 | `windowSwitchWhileSettlingFollowsTheAppDecision`, `windowSwitchAfterSettlingStillWorks` |
| (2026-10-03) 창이 40 ms 안에 또 바뀌거나 창 전환 직후 다른 앱으로 넘어가면, 거쳐 간 창의 기억이 덮였고 예약된 창 전환이 다음 앱에서 실행돼 그 앱의 기억 복원을 막았다 | 창 전환도 대기 세대로 관리한다. 대기 중에 떠난 창은 기록하지 않고, 다음 창 전환·앱 전환·`cancelPendingWork`가 예약을 취소한다 | `windowFrontForLessThanTheSettleDelayKeepsItsMemory`, `appSwitchRightAfterAWindowSwitchKeepsThatWindowsMemory`, `appSwitchRightAfterAWindowSwitchDoesNotRunTheStaleWindowSwitch` |
| 로그 폴더를 지우면 지워진 파일에 계속 써서 로그가 사라졌다 | 쓰기 전에 파일이 지워졌는지(링크 수 0) 보고 새로 연다 | `recreatesTheFileWhenTheLogFolderIsDeleted` |
| 색 설정 값 하나가 깨지면 모든 사용자 색이 지워졌다 | 깨진 항목만 버린다 | `oneCorruptColorKeepsTheOthers` |
| (2026-10-03) 켜기/끄기·크기 설정에 다른 타입이나 읽을 수 없는 글자가 있으면 기본값이 아니라 꺼짐·0으로 읽혔다(상태 막대가 이유 없이 꺼짐). 색과 규칙이 달랐다 | 깨진 항목만 기본값으로 읽고 키를 지운다. 손으로 넣을 법한 YES/NO·true/false·1/0과 숫자 글자는 읽는다. NaN·무한대·불리언 크기는 깨진 값이다. 무시한 키 이름을 실행 로그에 남긴다 | `SettingsStoreCorruptValueTests` |
| 앱별 기억 값 하나가 깨지면 모든 기억이 지워졌다 | 깨진 항목만 버린다 | `oneCorruptMemoryEntryKeepsTheOthers` |
| 앱별 기억 순서가 다시 실행하면 무작위가 되어, 200개를 넘을 때 오래된 것이 아닌 아무 앱이나 지웠다 | 순서를 따로 저장한다(`appInputSourcesOrder`). 순서가 없던 이전 기억은 이름순으로 앞에 둔다 | `evictionOrderSurvivesRelaunch` |

### 고치지 않은 것
- **자동 전환 뒤 0.1초 안에 키 입력 없이(Caps Lock 한/영, 입력 메뉴) 직접 바꾼 경우:** 되돌린다. ADR 0037에서 받아들인 한계다. 앱 전환 직후 0.1초 안에 그렇게 바꾸는 일은 드물다.

## 결과
- 테스트: Core 254개, 앱 71개.
- 판정 규칙이 바뀌었으므로 측정을 다시 했다([data/0043-mistype-eval.md](data/0043-mistype-eval.md)).
  - 영문 모드로 친 한글을 치는 중에 잡는 비율: 88.2% / 79.6% → 87.3% / 78.3%, 평균 3.9 → 4.0타째. 고 → 과처럼 바뀔 음절을 기다리기 때문이다. 단어 끝까지 합친 검출은 97.3% / 93.2%로 같다.
  - 한글 모드로 친 영어와 모든 오탐: 그대로다(영어 0.02–0.04, 코드 0.27–0.32, 한국어 0.00–0.12 /1000).
- 수동 확인: TESTING.md 체크리스트(설정 창을 그냥 닫기, 권한 취소, 메시지 연속 표시).
