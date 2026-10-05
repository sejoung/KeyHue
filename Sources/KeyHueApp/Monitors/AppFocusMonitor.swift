import AppKit

/// 활성 Application·Space·키보드 포커스 모니터 변경을 NSWorkspace notification으로 감지한다.
@MainActor
final class AppFocusMonitor {
    struct ActiveApp: Equatable {
        let bundleID: String?
        let pid: pid_t
    }

    private var observers: [NSObjectProtocol] = []

    private(set) var current: ActiveApp?

    var onAppActivated: ((_ previous: ActiveApp?, _ current: ActiveApp) -> Void)?
    var onSpaceChanged: (() -> Void)?
    var onWake: (() -> Void)?
    /// 키보드 포커스가 있는 모니터가 바뀌었다. 같은 앱의 다른 모니터 창으로 옮겨도 온다(ADR 0063).
    var onActiveDisplayChanged: (() -> Void)?

    /// 공개 상수가 없는 NSWorkspace 알림. 2026-10-04 macOS 26에서 포커스 모니터가 바뀔 때마다 왔고,
    /// 그때 `NSScreen.main`은 이미 새 모니터였다. 오지 않으면 앱 전환·Space 변경 때만 갱신된다.
    static let activeDisplayDidChange = Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification")

    func start() {
        if let app = NSWorkspace.shared.frontmostApplication, !Self.isSelf(app) {
            current = ActiveApp(bundleID: app.bundleIdentifier, pid: app.processIdentifier)
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier
            let pid = app.processIdentifier
            let isSelf = Self.isSelf(app)
            MainActor.assumeIsolated { self?.activated(ActiveApp(bundleID: bundleID, pid: pid), isSelf: isSelf) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSpaceChanged?() }
        })
        observers.append(center.addObserver(
            forName: Self.activeDisplayDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onActiveDisplayChanged?() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake?() }
        })
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    private func activated(_ app: ActiveApp, isSelf: Bool) {
        // KeyHue 자신(메뉴/권한 안내 alert)이 활성화된 것은 사용자 앱 전환으로 보지 않는다.
        guard !isSelf, app != current else { return }
        let previous = current
        current = app
        onAppActivated?(previous, app)
    }

    nonisolated private static func isSelf(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}
