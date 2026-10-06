import AppKit
import KeyHueCore

/// 앱 진입점. 실행 파일(`Sources/KeyHue/main.swift`)은 이것만 부른다.
/// 앱 코드를 라이브러리(KeyHueApp)로 두어야 테스트(KeyHueAppTests)에서 불러올 수 있다(ADR 0022).
@MainActor
public enum KeyHueAppMain {
    public static func run() -> Never {
        // Internal worker modes must finish before AppDelegate/logging/UI starts.
        switch WorkerCommand.parse(Array(CommandLine.arguments.dropFirst())) {
        case .app: break
        case .invalid: exit(WorkerCommand.usageError)
        case .worker(let command): runWorker(command)
        }
        let app = NSApplication.shared

        // 매뉴얼용 스크린샷 모드(scripts/screenshots.sh). Dock에 나타나지 않게 하고 이미지만 만든 뒤 끝낸다.
        if CommandLine.arguments.contains(DocScreenshots.flag) {
            app.setActivationPolicy(.accessory)
            _ = DocScreenshots.runIfRequested()
            exit(0)
        }

        // Dock 표시 여부(설정)는 AppDelegate.applicationWillFinishLaunching에서 적용한다.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }

    private static func runWorker(_ command: WorkerCommand) -> Never {
        switch command {
        case .selectInputSource(let id):
            guard InputSourceController.selectNative(sourceID: id) else { exit(1) }
            // Let TSM publish the selection before this short-lived process exits.
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            exit(InputSourceController.current()?.id == id ? 0 : 1)
        case .selectInputSourceRepairing(let id):
            // Same repair as the app: KeyHue's own selection, then the server's acknowledgement.
            let poster = InputSourceShortcutPoster()
            let repair = SystemSessionRepair.make(poster: poster)
            let acknowledgements = InputMethodAcknowledgementMonitor()
            var outcome: InputMethodSessionRepair.Outcome?
            repair.onFinished = { outcome = $0 }
            // Registered before selecting: the server answers the selection itself.
            acknowledgements.start { repair.acknowledged(modeID: $0) }
            let previous = InputSourceController.current()?.id
            guard InputSourceController.selectNative(sourceID: id) else { exit(1) }
            repair.selected(sourceID: id, previousID: previous)
            let watched = id == InputMethodIntegration.hangulID || id == InputMethodIntegration.latinID
            let deadline = Date().addingTimeInterval(watched ? 2 : 0.04)
            while outcome == nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            acknowledgements.stop()
            // The outcome name only; no client or input details.
            print("session repair outcome=\(outcome.map { String(describing: $0) } ?? "none")")
            exit(InputSourceController.current()?.id == id ? 0 : 1)
        case .prepareUninstall:
            exit(UninstallPreparation.run() ? 0 : 1)
        case .loginItemStatus:
            print("login item: \(UninstallPreparation.loginItemStatusName)")
            exit(0)
        case .postBackspaces(let pid, let count):
            guard CGPreflightPostEventAccess() else { exit(WorkerCommand.noPermission) }
            TerminalKeyPostServer.postBackspaces(count, to: pid)
            // Exiting right after posting dropped the last key (2026-10-06 14:25: arrived=2 of=3).
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            exit(0)
        case .inputSourceStatus:
            let snapshot = InputSourceController.diagnosticSnapshot()
            if let data = try? JSONEncoder().encode(snapshot) { FileHandle.standardOutput.write(data) }
            exit(0)
        case .relaunchAfterInputMethod(let pid, let finishSetup):
            if let parent = NSRunningApplication(processIdentifier: pid) {
                guard parent.bundleIdentifier == Bundle.main.bundleIdentifier else { exit(WorkerCommand.usageError) }
                for _ in 0..<100 {
                    if parent.isTerminated { break }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                guard parent.isTerminated else { exit(1) }
            }
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = WorkerCommand.relaunchOpenArguments(bundlePath: Bundle.main.bundleURL.path, finishSetup: finishSetup)
            do { try launcher.run(); launcher.waitUntilExit(); exit(launcher.terminationStatus) } catch { exit(1) }
        }
    }
}
