import AppKit

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
