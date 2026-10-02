import Foundation

/// Internal diagnostic workers must not freeze the menu/settings indefinitely.
enum InputSourceWorker {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 2) -> (status: Int32, output: Data)? {
        let process = Process()
        let output = Pipe()
        let ended = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch {
            Log.inputSource.error("input source worker launch failed operation=\(arguments.first ?? "none") error=\(error)")
            return nil
        }
        guard ended.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if ended.wait(timeout: .now() + 0.2) != .success { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            Log.inputSource.error("input source worker timed out operation=\(arguments.first ?? "none") timeout=\(timeout)")
            return nil
        }
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
    }
}
