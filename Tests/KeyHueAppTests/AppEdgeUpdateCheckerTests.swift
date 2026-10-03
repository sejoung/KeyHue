import Foundation
import Testing
@testable import KeyHueApp
import KeyHueCore

// 업데이트 확인(ADR 0044)의 경계 조건. 네트워크 대신 응답 바이트와 가짜 fetch·시간을 쓴다.

@Suite("GitHub release validation edge cases")
struct AppEdgeGitHubReleaseTests {
    static func release(
        tag: Any = "v0.10.0", draft: Any = false, prerelease: Any = false,
        assets: Any = [["name": "KeyHue.zip", "state": "uploaded"]], extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": assets]
        object.merge(extra) { $1 }
        return object
    }

    static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test func realAPIFieldsAndOtherAssetsAreIgnored() throws {
        // 실제 응답에는 본문·URL·크기 등 많은 필드와 여러 첨부 파일이 있다. 필요한 것만 본다.
        let object = Self.release(
            assets: [
                ["name": "KeyHue.zip.sha256", "state": "uploaded", "size": 64],
                ["name": "KeyHue.zip", "state": "new", "size": 0],
                ["name": "KeyHue-0.10.0.zip", "state": "uploaded", "size": 1_234_567,
                 "browser_download_url": "https://github.com/sejoung/KeyHue/releases/download/v0.10.0/KeyHue-0.10.0.zip"]
            ],
            extra: ["name": "KeyHue 0.10.0", "body": "## Changes\n- 한글 ✓", "html_url": "https://example.invalid", "id": 1]
        )
        #expect(try GitHubReleaseFetcher.decode(Self.data(object), statusCode: 200).string == "0.10.0")
    }

    /// URLSession은 리디렉션을 따라가므로 3xx가 그대로 오면 비정상 응답이다. 200 외에는 모두 실패다.
    @Test(arguments: [201, 202, 204, 206, 301, 302, 304, 307, 401, 403, 422, 451, 502, 503])
    func everyStatusOtherThan200IsAFailure(_ status: Int) throws {
        #expect(throws: (any Error).self) { try GitHubReleaseFetcher.decode(Self.data(Self.release()), statusCode: status) }
    }

    @Test func bodySizeLimitIsInclusive() throws {
        // 1 MiB까지는 받고 그보다 크면 (내용이 올바라도) 거부한다.
        let limit = 1_048_576
        let base = try Self.data(Self.release(extra: ["body": ""])).count
        let atLimit = try Self.data(Self.release(extra: ["body": String(repeating: "a", count: limit - base)]))
        #expect(atLimit.count == limit)
        #expect(try GitHubReleaseFetcher.decode(atLimit, statusCode: 200).string == "0.10.0")
        let over = try Self.data(Self.release(extra: ["body": String(repeating: "a", count: limit - base + 1)]))
        #expect(over.count == limit + 1)
        #expect(throws: (any Error).self) { try GitHubReleaseFetcher.decode(over, statusCode: 200) }
    }

    @Test(arguments: [
        "null", "[]", "\"v0.10.0\"", "", "{\"tag_name\":\"v0.10.0\"}",
        #"{"tag_name":"v0.10.0","draft":false,"prerelease":false}"#,
        #"{"tag_name":null,"draft":false,"prerelease":false,"assets":[]}"#,
        #"{"tag_name":"v0.10.0","draft":"false","prerelease":false,"assets":[{"name":"KeyHue.zip","state":"uploaded"}]}"#,
        #"{"tag_name":"v0.10.0","draft":false,"prerelease":0,"assets":[{"name":"KeyHue.zip","state":"uploaded"}]}"#,
        #"{"tag_name":"v0.10.0","draft":false,"prerelease":false,"assets":{"name":"KeyHue.zip","state":"uploaded"}}"#,
        #"{"tag_name":"v0.10.0","draft":false,"prerelease":false,"assets":[{"name":"KeyHue.zip"}]}"#,
        #"{"tag_name":"v0.10.0","draft":false,"prerelease":false,"assets":[]}"#,
        #"{"message":"API rate limit exceeded for 1.2.3.4.","documentation_url":"https://docs.github.com/rest"}"#,
        #"{"tag_name":"v0.10.0","draft":false,"prerelease":false,"assets":[{"name":"KeyHue.zip","state":"uploaded"}]"#
    ])
    func malformedOrIncompleteBodiesAreFailures(_ body: String) {
        // 한도 초과 응답이 200으로 오는 경우(프록시 등)도 최신 버전으로 보이면 안 된다.
        #expect(throws: (any Error).self) { try GitHubReleaseFetcher.decode(Data(body.utf8), statusCode: 200) }
    }

    @Test(arguments: [
        "V0.10.0", "vv0.10.0", "v0.10", "v0.10.0.1", "v00.10.0", "v0.010.0", " v0.10.0", "v0.10.0 ", "v0.10.0\n",
        "release-0.10.0", "v0.10.0-rc.1", "v0.10.0+1", "v", "", "v-1.0.0", "v１.0.0"
    ])
    func nonCanonicalTagsAreRejected(_ tag: String) throws {
        #expect(throws: (any Error).self) { try GitHubReleaseFetcher.decode(Self.data(Self.release(tag: tag)), statusCode: 200) }
    }

    @Test(arguments: ["KeyHue-0.9.0.zip", "keyhue.zip", "KeyHue.ZIP", "KeyHue.zip.sig", "KeyHue-v0.10.0.zip", "KeyHue-0.10.zip", ""])
    func assetMustBeTheZipForThisRelease(_ name: String) throws {
        let object = Self.release(assets: [["name": name, "state": "uploaded"]])
        #expect(throws: (any Error).self) { try GitHubReleaseFetcher.decode(Self.data(object), statusCode: 200) }
    }

    @Test(arguments: ["new", "starter", "", "Uploaded"])
    func assetMustBeFullyUploaded(_ state: String) throws {
        let object = Self.release(assets: [["name": "KeyHue.zip", "state": state]])
        #expect(throws: (any Error).self) { try GitHubReleaseFetcher.decode(Self.data(object), statusCode: 200) }
    }

    @Test func draftAndPrereleaseAreRejectedTogetherOrAlone() throws {
        for (draft, prerelease) in [(true, true), (true, false), (false, true)] {
            let object = Self.release(draft: draft, prerelease: prerelease)
            #expect(throws: (any Error).self) { try GitHubReleaseFetcher.decode(Self.data(object), statusCode: 200) }
        }
    }
}

@MainActor
@Suite("Update checking edge cases")
struct AppEdgeUpdateCheckerTests {
    typealias Clock = UpdateCheckerTests.Clock
    typealias Fetcher = UpdateCheckerTests.Fetcher
    typealias BlockingFetcher = UpdateCheckerTests.BlockingFetcher

    @Test(arguments: ["—", "", "0.10", "0.10.0-dev", "1.0.0 (42)"])
    func unparsableInstalledVersionNeverContactsGitHub(_ installed: String) async {
        // 번들 없이 실행(버전 "—")하거나 개발 빌드면 비교할 수 없다. 요청하지 않고 실패로 보인다.
        let defaults = makeTestDefaults(), scheduler = FakeScheduler(), fetcher = Fetcher()
        defaults.set("0.10.0", forKey: UpdateChecker.Key.latestVersion)
        let checker = UpdateChecker(currentVersion: installed, defaults: defaults, scheduler: scheduler, fetch: fetcher.fetch)
        #expect(checker.state.availableVersion == nil)
        #expect(checker.releaseURL == nil)
        checker.configure(automatic: true)
        scheduler.advance(by: 172_800)
        #expect(fetcher.calls == 0)
        await checker.checkNow()
        #expect(fetcher.calls == 0)
        #expect(checker.state.failed)
        #expect(!checker.state.isChecking)
        #expect(defaults.object(forKey: UpdateChecker.Key.lastAttempt) == nil)
        #expect(AppEdgeText.anyLanguage("Could not check for updates. Try again later.").contains(checker.statusText))
    }

    @Test(arguments: ["garbage", "", "0.11.0-beta", "v0.11", "01.0.0"])
    func corruptCachedVersionIsIgnored(_ cached: String) {
        let defaults = makeTestDefaults()
        defaults.set(cached, forKey: UpdateChecker.Key.latestVersion)
        defaults.set("not a date", forKey: UpdateChecker.Key.lastChecked)
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, fetch: Fetcher().fetch)
        #expect(checker.state.availableVersion == nil)
        #expect(checker.state.lastChecked == nil)
        #expect(checker.releaseURL == nil)
        #expect(!checker.state.failed)
    }

    @Test func clockMovedBackwardsChecksRightAwayThenWaitsADay() async {
        // 마지막 시도가 미래(시계를 뒤로 돌림)면 그 기준을 믿지 않고 바로 확인한다(ADR 0044).
        let defaults = makeTestDefaults(), clock = Clock(), scheduler = FakeScheduler(), fetcher = Fetcher()
        defaults.set(clock.date.addingTimeInterval(30 * 86_400), forKey: UpdateChecker.Key.lastAttempt)
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, now: { clock.date }, scheduler: scheduler, fetch: fetcher.fetch)
        checker.configure(automatic: true)
        scheduler.advance(by: 0)
        await checker.checkNow() // 시작한 자동 요청을 기다린다
        #expect(fetcher.calls == 1)
        #expect(defaults.object(forKey: UpdateChecker.Key.lastAttempt) as? Date == clock.date)
        scheduler.advance(by: 86_399)
        #expect(fetcher.calls == 1)
    }

    @Test func automaticChecksRepeatEveryDayOnTheirOwn() async {
        let defaults = makeTestDefaults(), clock = Clock(), scheduler = FakeScheduler(), fetcher = Fetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, now: { clock.date }, scheduler: scheduler, fetch: fetcher.fetch)
        checker.configure(automatic: true)
        scheduler.advance(by: 0)
        await checker.checkNow()
        #expect(fetcher.calls == 1)
        for day in 2...3 {
            clock.date.addTimeInterval(86_400)
            scheduler.advance(by: 86_399)
            #expect(fetcher.calls == day - 1)
            scheduler.advance(by: 1)
            await checker.checkNow()
            #expect(fetcher.calls == day)
        }
    }

    @Test func failedAutomaticCheckRetriesOnTheNextDayAndClearsFailure() async {
        let defaults = makeTestDefaults(), clock = Clock(), scheduler = FakeScheduler(), fetcher = Fetcher()
        fetcher.fails = true
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, now: { clock.date }, scheduler: scheduler, fetch: fetcher.fetch)
        checker.configure(automatic: true)
        scheduler.advance(by: 0)
        await checker.checkNow()
        #expect(checker.state.failed)
        #expect(defaults.object(forKey: UpdateChecker.Key.lastChecked) == nil)
        fetcher.fails = false
        clock.date.addTimeInterval(86_400)
        scheduler.advance(by: 86_400)
        await checker.checkNow()
        #expect(fetcher.calls == 2)
        #expect(!checker.state.failed)
        #expect(checker.state.availableVersion == "0.10.0")
    }

    @Test func turningOffAutomaticChecksKeepsAManualCheckInFlight() async {
        let defaults = makeTestDefaults(), scheduler = FakeScheduler(), fetcher = BlockingFetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, scheduler: scheduler, fetch: fetcher.fetch)
        checker.configure(automatic: true) // 예약만 하고 아직 시간을 흘리지 않는다
        let manual = Task { await checker.checkNow() }
        await fetcher.waitUntilStarted()
        checker.configure(automatic: false)
        #expect(checker.state.isChecking) // 사용자가 직접 시작한 확인은 취소하지 않는다
        fetcher.complete()
        await manual.value
        #expect(checker.state.availableVersion == "0.10.0")
        #expect(defaults.object(forKey: UpdateChecker.Key.lastChecked) != nil)
        scheduler.advance(by: 172_800) // 무효화된 예약은 아무 일도 하지 않는다
        #expect(fetcher.calls == 1)
    }

    @Test func manualCheckJoiningAnAutomaticRequestSurvivesTurningAutomaticOff() async {
        let defaults = makeTestDefaults(), scheduler = FakeScheduler(), fetcher = BlockingFetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, scheduler: scheduler, fetch: fetcher.fetch)
        checker.configure(automatic: true)
        scheduler.advance(by: 0)
        await fetcher.waitUntilStarted()
        // checkNow의 동기 부분(자동 요청을 수동으로 넘겨받기)이 먼저 실행된 뒤 자동 확인을 끄고 응답을 보낸다.
        Task {
            checker.configure(automatic: false)
            fetcher.complete()
        }
        await checker.checkNow()
        #expect(fetcher.calls == 1)
        #expect(checker.state.availableVersion == "0.10.0")
        #expect(!checker.state.failed)
    }

    @Test func enablingAutomaticChecksDuringAManualCheckSchedulesOnlyAfterIt() async {
        let defaults = makeTestDefaults(), clock = Clock(), scheduler = FakeScheduler(), fetcher = BlockingFetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, now: { clock.date }, scheduler: scheduler, fetch: fetcher.fetch)
        let manual = Task { await checker.checkNow() }
        await fetcher.waitUntilStarted()
        checker.configure(automatic: true)
        scheduler.advance(by: 0) // 진행 중인 요청이 있으니 두 번째 요청을 만들지 않는다
        #expect(fetcher.calls == 1)
        fetcher.complete()
        await manual.value
        scheduler.advance(by: 86_399)
        #expect(fetcher.calls == 1)
        clock.date.addTimeInterval(86_400)
        scheduler.advance(by: 1)
        await fetcher.waitUntilStarted()
        #expect(fetcher.calls == 2)
        fetcher.complete()
        await checker.checkNow()
    }

    @Test func newestReleaseIsTheSourceOfTruthEvenIfItIsOlderThanTheCachedOne() async {
        // 릴리즈를 내렸으면(최신이 더 낮아졌으면) 예전에 본 버전을 계속 안내하지 않는다.
        let defaults = makeTestDefaults(), fetcher = Fetcher()
        defaults.set("0.11.0", forKey: UpdateChecker.Key.latestVersion)
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, fetch: fetcher.fetch)
        #expect(checker.state.availableVersion == "0.11.0")
        await checker.checkNow()
        #expect(checker.state.availableVersion == "0.10.0")
        fetcher.version = ReleaseVersion("0.9.0")!
        await checker.checkNow()
        #expect(checker.state.availableVersion == nil)
        #expect(checker.releaseURL == nil)
        #expect(defaults.string(forKey: UpdateChecker.Key.latestVersion) == "0.9.0")
    }

    @Test func observersSeeTheCheckStartAndFinish() async {
        // 메뉴 항목은 이 알림으로 "확인 중"(비활성) ↔ 결과를 오간다.
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), fetch: Fetcher().fetch)
        var seen: [Bool] = []
        checker.addObserver { seen.append(checker.state.isChecking) }
        await checker.checkNow()
        #expect(seen.contains(true))
        #expect(seen.last == false)
    }

    @Test func statusTextAndMenuTitleFollowTheState() async {
        let defaults = makeTestDefaults(), fetcher = Fetcher()
        let upToDate = UpdateChecker(currentVersion: "0.10.0", defaults: defaults, fetch: fetcher.fetch)
        #expect(AppEdgeText.anyLanguage("Updates have not been checked yet.").contains(upToDate.statusText))
        #expect(AppEdgeText.anyLanguage("Check for Updates…").contains(upToDate.menuTitle))
        await upToDate.checkNow()
        #expect(AppEdgeText.anyLanguage("You have the latest version.").contains(upToDate.statusText))

        let behind = UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), fetch: fetcher.fetch)
        await behind.checkNow()
        #expect(AppEdgeText.anyLanguage("New version v%@ is available.", "0.10.0").contains(behind.statusText))
        // 확인이 실패해도 이미 찾은 업데이트의 다운로드 메뉴는 남고, 상태 문구는 실패를 알린다.
        fetcher.fails = true
        await behind.checkNow()
        #expect(AppEdgeText.anyLanguage("Could not check for updates. Try again later.").contains(behind.statusText))
        #expect(AppEdgeText.anyLanguage("Download New Version v%@…", "0.10.0").contains(behind.menuTitle))
        #expect(behind.releaseURL?.absoluteString == "https://github.com/sejoung/KeyHue/releases/tag/v0.10.0")
    }
}
