import AppKit
import Foundation
import Testing
@testable import KeyHueApp
import KeyHueCore

@Suite("GitHub release validation")
struct GitHubReleaseTests {
    static func payload(tag: String = "v0.10.0", draft: Bool = false, prerelease: Bool = false, asset: String = "KeyHue.zip", state: String = "uploaded") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": [["name": asset, "state": state]]
        ])
    }

    @Test func acceptsOnlyPublishedStableDownloadableReleases() throws {
        #expect(try GitHubReleaseFetcher.decode(Self.payload(), statusCode: 200).string == "0.10.0")
        #expect(try GitHubReleaseFetcher.decode(Self.payload(asset: "KeyHue-0.10.0.zip"), statusCode: 200).string == "0.10.0")
        for data in try [Self.payload(draft: true), Self.payload(prerelease: true), Self.payload(tag: "v0.10.0-beta"),
                         Self.payload(tag: "0.10.0"), Self.payload(asset: "source.zip"), Self.payload(state: "new"),
                         Data("{}".utf8), Data("not JSON".utf8)] {
            #expect(throws: (any Error).self) { try GitHubReleaseFetcher.decode(data, statusCode: 200) }
        }
    }

    @Test(arguments: [403, 404, 429, 500])
    func errorsAreNotReportedAsUpToDate(_ status: Int) throws {
        #expect(throws: (any Error).self) { try GitHubReleaseFetcher.decode(Self.payload(), statusCode: status) }
    }
}

@MainActor
@Suite("Update checking")
struct UpdateCheckerTests {
    @MainActor final class Clock { var date = Date(timeIntervalSince1970: 100_000) }
    @MainActor final class Fetcher {
        var calls = 0
        var fails = false
        var version = ReleaseVersion("0.10.0")!
        func fetch() async throws -> ReleaseVersion {
            calls += 1
            if fails { throw GitHubReleaseFetcher.Failure.invalidResponse }
            return version
        }
    }

    @Test func automaticScheduleSurvivesRelaunchAndWakeWithoutExtraRequests() async {
        let defaults = makeTestDefaults(), clock = Clock(), scheduler = FakeScheduler(), fetcher = Fetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, now: { clock.date }, scheduler: scheduler, fetch: fetcher.fetch)
        checker.configure(automatic: true)
        scheduler.advance(by: 0)
        await checker.checkNow() // 요청 완료를 기다린다. 이미 시작한 자동 요청을 재사용한다.
        #expect(fetcher.calls == 1)
        #expect(checker.state.availableVersion == "0.10.0")
        #expect(checker.releaseURL?.absoluteString == "https://github.com/sejoung/KeyHue/releases/tag/v0.10.0")
        let relaunched = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, now: { clock.date }, scheduler: scheduler, fetch: fetcher.fetch)
        relaunched.configure(automatic: true)
        relaunched.configure(automatic: true) // wake가 예약을 다시 만들어도 요청을 중복하지 않는다.
        #expect(relaunched.state.availableVersion == "0.10.0")
        scheduler.advance(by: 86_399)
        #expect(fetcher.calls == 1)
        checker.configure(automatic: false)
        clock.date.addTimeInterval(86_400)
        scheduler.advance(by: 1)
        await relaunched.checkNow()
        #expect(fetcher.calls == 2)
    }

    @Test func disablingAutomaticChecksInvalidatesPendingWorkButAllowsManualChecks() async {
        let scheduler = FakeScheduler(), fetcher = Fetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), scheduler: scheduler, fetch: fetcher.fetch)
        checker.configure(automatic: true)
        checker.configure(automatic: false)
        scheduler.advance(by: 86_400)
        #expect(fetcher.calls == 0)
        await checker.checkNow()
        #expect(fetcher.calls == 1)
        scheduler.advance(by: 172_800)
        #expect(fetcher.calls == 1)
    }

    @Test func failureKeepsKnownUpdateAndDoesNotAdvanceLastSuccessfulCheck() async {
        let defaults = makeTestDefaults(), clock = Clock(), scheduler = FakeScheduler(), fetcher = Fetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, now: { clock.date }, scheduler: scheduler, fetch: fetcher.fetch)
        await checker.checkNow()
        let lastChecked = checker.state.lastChecked
        fetcher.fails = true
        clock.date.addTimeInterval(10)
        await checker.checkNow()
        #expect(checker.state.failed)
        #expect(!checker.state.isChecking)
        #expect(checker.state.lastChecked == lastChecked)
        #expect(checker.state.availableVersion == "0.10.0")
        checker.configure(automatic: true)
        scheduler.advance(by: 86_399)
        #expect(fetcher.calls == 2) // 실패 뒤에도 하루 동안 자동 재시도하지 않는다.
    }

    @Test(arguments: ["0.10.0", "0.11.0"])
    func sameOrOlderReleaseDoesNotOfferDownload(_ installed: String) async {
        let defaults = makeTestDefaults(), fetcher = Fetcher()
        defaults.set("0.10.0", forKey: UpdateChecker.Key.latestVersion)
        let checker = UpdateChecker(currentVersion: installed, defaults: defaults, fetch: fetcher.fetch)
        #expect(checker.releaseURL == nil)
        await checker.checkNow()
        #expect(checker.state.availableVersion == nil)
        #expect(!checker.state.failed)
    }

    @MainActor final class BlockingFetcher {
        var calls = 0
        var result: CheckedContinuation<ReleaseVersion, any Error>?
        var started: CheckedContinuation<Void, Never>?
        var finished: CheckedContinuation<Void, Never>?
        func fetch() async throws -> ReleaseVersion {
            calls += 1
            defer { finished?.resume(); finished = nil }
            return try await withCheckedThrowingContinuation { continuation in
                result = continuation
                started?.resume()
                started = nil
            }
        }
        func waitUntilStarted() async {
            if result != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func complete() {
            result?.resume(returning: ReleaseVersion("0.10.0")!)
            result = nil
        }
        func waitUntilFinished() async {
            await withCheckedContinuation { finished = $0 }
        }
    }

    @Test func manualCheckSharesAnInFlightRequest() async {
        let fetcher = BlockingFetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), fetch: fetcher.fetch)
        let first = Task { await checker.checkNow() }
        await fetcher.waitUntilStarted()
        Task { fetcher.complete() }
        await checker.checkNow()
        await first.value
        #expect(fetcher.calls == 1)
    }

    @Test func turningOffAutomaticCheckDiscardsInFlightResult() async {
        let defaults = makeTestDefaults(), scheduler = FakeScheduler(), fetcher = BlockingFetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: defaults, scheduler: scheduler, fetch: fetcher.fetch)
        checker.configure(automatic: true)
        scheduler.advance(by: 0)
        await fetcher.waitUntilStarted()
        checker.configure(automatic: false)
        Task { fetcher.complete() }
        await fetcher.waitUntilFinished()
        #expect(!checker.state.isChecking)
        #expect(checker.state.availableVersion == nil)
        #expect(defaults.object(forKey: UpdateChecker.Key.lastChecked) == nil)
        scheduler.advance(by: 172_800)
        #expect(fetcher.calls == 1)
    }

    @Test func manualMenuIsDisabledWhileCheckIsInFlight() async {
        let fetcher = BlockingFetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), fetch: fetcher.fetch)
        let pending = Task { await checker.checkNow() }
        await fetcher.waitUntilStarted()
        let target = AppMenuTests.Target()
        let menu = MainMenu.make(target: target, showSettings: #selector(AppMenuTests.Target.settings), showAbout: #selector(AppMenuTests.Target.about), updates: checker, checkUpdates: #selector(AppMenuTests.Target.about))
        #expect(menu.items.first?.submenu?.items.first { $0.title == checker.menuTitle }?.isEnabled == false)
        fetcher.complete()
        await pending.value
    }

    @Test func mainMenuReflectsAvailableVersion() async {
        let fetcher = Fetcher()
        let checker = UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), fetch: fetcher.fetch)
        await checker.checkNow()
        let target = AppMenuTests.Target()
        let menu = MainMenu.make(target: target, showSettings: #selector(AppMenuTests.Target.settings), showAbout: #selector(AppMenuTests.Target.about), updates: checker, checkUpdates: #selector(AppMenuTests.Target.about))
        let item = menu.items.first?.submenu?.items.first { $0.title.contains("0.10.0") }
        #expect(item?.isEnabled == true)
        #expect(item?.target === target)
    }
}
