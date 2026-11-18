# 0095. 다른 앱이 보안 입력을 잡고 있으면 알리고, 풀린 뒤 첫 전환에서 KeyHue 모드로 돌아온다

- 상태: Accepted (구현·회귀 테스트, 실제 재발 시 안내 문구와 로그는 추가 관찰)
- 날짜: 2026-11-18
- 관련: [0071](0071-route-through-the-leaving-mode-and-wait-for-modifier-release.md), [0082](0082-key-acknowledgement-system-abc-and-suspect-log.md), [0094](0094-pause-routing-without-disabling-the-user-preference.md)

## 맥락

사용자가 "갑자기 KeyHue 입력기가 안 먹고 macOS 입력기만 켜진다"고 했다. 11월 18일 13:04:44에 Chrome에서 Touch ID·암호 인증(LocalAuthentication)이 있었다. 13:04:49에 Slack으로 넘어간 뒤 13:12:15에 Chrome으로 돌아올 때까지 약 8분간 다음이 반복됐다.

- 유틸리티: KeyHue 모드를 고르면 약 10ms 뒤 ABC로 되돌아왔다(`auto reset: retrying ... (overwritten)`). 세션 복구는 `skipped: secure input`.
- 입력기: Slack, 메모, 카카오톡, Chrome, IntelliJ, Android Studio에서 `activation rejected selected=foreign-or-missing`.
- ⌘Space는 ABC와 시스템 두벌식 사이만 오갔다.

Chrome 쪽으로 다시 전환하자 곧바로 풀렸다(`input method routing: ok`). 11월 12일 17:09–17:13에도 Chrome→Slack 전환마다 같은 일이 있었다.

어떤 프로세스든 보안 입력(secure event input)을 잡고 있으면 macOS는 앞 앱이 아니어도 서드파티 입력기를 선택된 채로 두지 않는다. KeyHue가 이것을 우회할 방법은 없다. 그런데 사용자에게는 이유가 보이지 않았다. 로그에도 누가 잡았는지가 없어서 Chrome은 정황으로만 추정했다.

또 보안 입력 중에 ABC와 두벌식을 오간 뒤 보안 입력이 풀려도, 다음 ⌘Space가 두 우회 소스 사이에서 계속 돌았다. 라우터가 "KeyHue 모드에서 떠난 우회"만 라우팅하기 때문이다. 다른 앱으로 전환하기 전까지 KeyHue 모드로 돌아오지 않았다.

## 결정

- **안내:** 입력기가 연결된 상태에서 우회 소스(ABC, 시스템 두벌식)가 선택되어 있고, 보안 입력을 잡은 프로세스가 앞 앱이 아니면 화면 아래 안내를 띄운다. 제목은 "Google Chrome에서 보안 입력 중"이다. 설명은 "끝날 때까지 macOS 입력 소스만 쓸 수 있습니다. Google Chrome(으)로 돌아가거나 암호 입력란을 닫으세요."다. 잘못된 언어 경고·고침 실패 안내와 같은 자리에 같은 모양으로 띄우고, 4초 유지한다.
- **안내하지 않는 경우:** 앞 앱 자신의 암호 입력란(ABC가 정상이다), 로그인 창, 잡은 프로세스를 알 수 없을 때, 입력기가 연결되지 않았을 때.
- **빈도:** 같은 보안 입력 동안 한 번만 띄운다. 보안 입력이 풀렸다가 다시 잡혀도 30초 안에는 다시 띄우지 않는다(11/12처럼 전환마다 잡는 앱).
- **시점:** 보안 입력이 풀릴 때 오는 알림이 없고 KeyHue는 폴링하지 않는다. 입력 소스 변경과 앱 활성화 때만 확인한다. 덮어쓰기는 수십 ms 안에 여러 번 오므로 마지막 변경 뒤 0.3초를 기다렸다 본다.
- **로그:** 잡은 프로세스를 `secure input held by pid 1214 com.google.Chrome ...`, `session repair skipped: secure input (pid ...)`로 남긴다. 입력 내용은 읽지 않는다.
- **복귀:** 라우터가 시스템 우회로 기록한 상태에서 보안 입력이 풀린 뒤 우회 소스끼리 전환되면, 새 소스 언어의 KeyHue 모드로 돌아간다. 두벌식이면 KeyHue 한글, ABC면 KeyHue 영문이다. 0071처럼 다른 모드를 먼저 고르므로 다음 ⌘Space는 두 KeyHue 모드를 오간다. 시스템 우회 기록이 없으면 사용자가 고른 우회 소스이므로 그대로 둔다.

## 검증

- `SecureInputNoticePolicyTests`: 다른 앱이 잡으면 한 번, 앞 앱·로그인 창·알 수 없는 프로세스·KeyHue 모드 선택·연결 없음은 안내 없음, 30초 간격.
- `SecureInputNotifierTests`: 13:04:49처럼 30ms 안에 세 번 덮어써도 안내 하나, 잡은 앱 이름 표시, 앞 앱의 암호 입력란은 안내 없음.
- `InputMethodIntegrationTests.toggleBetweenDetoursAfterSecureInputReturnsToKeyHue`: 수정 전 코드에서 실패하고 수정 후 통과. 시스템 우회 기록이 없는 우회 간 전환은 그대로 둔다.
- 전체 `swift test`(239·694·327개)와 `scripts/swift-lint.sh` 통과.
