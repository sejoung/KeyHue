import AppKit
import KeyHueCore
import SwiftUI

struct UpdateCheckState: Equatable {
    var isChecking = false
    var lastChecked: Date?
    var availableVersion: String?
    var failed = false
}

/// GitHub 공개 릴리즈를 읽기만 한다. 설치와 파일 다운로드는 브라우저에서 사용자가 한다(ADR 0044).
@MainActor
final class UpdateChecker: ObservableObject {
    enum Key {
        static let lastAttempt = "updates.lastAttempt"
        static let lastChecked = "updates.lastChecked"
        static let latestVersion = "updates.latestVersion"
    }

    let currentVersion: String
    @Published private(set) var state: UpdateCheckState {
        didSet { observers.forEach { $0() } }
    }
    private let defaults: UserDefaults
    private let now: () -> Date
    private let scheduler: Scheduling
    private let fetch: @MainActor () async throws -> ReleaseVersion
    private var observers: [() -> Void] = []
    private var automatic = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var automaticTask = false

    init(
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        scheduler: Scheduling = MainQueueScheduler(),
        fetch: @escaping @MainActor () async throws -> ReleaseVersion = GitHubReleaseFetcher.latest
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
        self.scheduler = scheduler
        self.fetch = fetch
        let cached = defaults.string(forKey: Key.latestVersion).flatMap(ReleaseVersion.init)
        let installed = ReleaseVersion(currentVersion)
        state = UpdateCheckState(
            lastChecked: defaults.object(forKey: Key.lastChecked) as? Date,
            availableVersion: cached.flatMap { latest in installed.map { latest > $0 ? latest.string : nil } ?? nil }
        )
    }

    func addObserver(_ observer: @escaping () -> Void) { observers.append(observer) }

    /// 실행·설정 변경·wake에서 예약을 다시 만든다. 이전 예약은 세대 번호로 무효화한다.
    func configure(automatic: Bool) {
        self.automatic = automatic
        generation += 1
        if !automatic, automaticTask {
            task?.cancel()
            task = nil
            automaticTask = false
            state.isChecking = false
        }
        scheduleNext()
    }

    private func scheduleNext() {
        guard automatic, task == nil, ReleaseVersion(currentVersion) != nil else { return }
        generation += 1
        let scheduledGeneration = generation
        let delay = UpdateCheckPolicy.delay(lastAttempt: defaults.object(forKey: Key.lastAttempt) as? Date, now: now())
        scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.automatic, self.generation == scheduledGeneration else { return }
            self.beginCheck(automatic: true)
        }
    }

    /// 자동 확인을 꺼도 수동 확인은 가능하다. 진행 중인 요청은 공유한다.
    func checkNow() async {
        if automaticTask { automaticTask = false }
        beginCheck(automatic: false)
        await task?.value
    }

    private func beginCheck(automatic: Bool) {
        guard task == nil else { return }
        guard let installed = ReleaseVersion(currentVersion) else {
            state.failed = true
            return
        }
        generation += 1
        automaticTask = automatic
        defaults.set(now(), forKey: Key.lastAttempt)
        state.failed = false
        state.isChecking = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let latest = try await self.fetch()
                try Task.checkCancellation()
                let checked = self.now()
                self.defaults.set(latest.string, forKey: Key.latestVersion)
                self.defaults.set(checked, forKey: Key.lastChecked)
                self.state = UpdateCheckState(lastChecked: checked, availableVersion: latest > installed ? latest.string : nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.state.isChecking = false
                self.state.failed = true
            }
            self.task = nil
            self.automaticTask = false
            self.scheduleNext()
        }
    }

    var menuTitle: String {
        if state.isChecking { return L("Checking for Updates…") }
        if let version = state.availableVersion { return L("Download New Version v%@…", version) }
        return L("Check for Updates…")
    }

    var releaseURL: URL? {
        guard let version = state.availableVersion, ReleaseVersion(version) != nil else { return nil }
        return URL(string: "https://github.com/sejoung/KeyHue/releases/tag/v\(version)")
    }

    var statusText: String {
        if state.isChecking { return L("Checking for Updates…") }
        if state.failed { return L("Could not check for updates. Try again later.") }
        if let version = state.availableVersion { return L("New version v%@ is available.", version) }
        return state.lastChecked == nil ? L("Updates have not been checked yet.") : L("You have the latest version.")
    }
}

enum GitHubReleaseFetcher {
    static let endpoint = URL(string: "https://api.github.com/repos/sejoung/KeyHue/releases/latest")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    enum Failure: Error { case invalidResponse }

    static func latest() async throws -> ReleaseVersion {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("KeyHue-UpdateCheck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return try decode(data, statusCode: http.statusCode)
    }

    static func decode(_ data: Data, statusCode: Int) throws -> ReleaseVersion {
        guard statusCode == 200, data.count <= 1_048_576 else { throw Failure.invalidResponse }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, let version = ReleaseVersion(release.tag_name),
              release.tag_name == "v\(version.string)",
              release.assets.contains(where: {
                  $0.state == "uploaded" && ($0.name == "KeyHue.zip" || $0.name == "KeyHue-\(version.string).zip")
              }) else { throw Failure.invalidResponse }
        return version
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
    }
}
