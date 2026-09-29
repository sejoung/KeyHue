import AppKit

/// 활성 Application 변경과 Space 변경을 NSWorkspace notification으로 감지한다.
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
