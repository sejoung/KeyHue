import Foundation

/// Internal diagnostic workers must not freeze the menu/settings indefinitely.
enum InputSourceWorker {
    /// Collects stdout while the worker runs, so output larger than the pipe
    /// buffer cannot block the worker until the timeout.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        let finished = DispatchSemaphore(value: 0)
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 2) -> (status: Int32, output: Data)? {
        let process = Process()
        let pipe = Pipe()
        let output = Output()
        let ended = DispatchSemaphore(value: 0)
        let deadline = DispatchTime.now() + timeout
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                output.finished.signal()
            } else {
                output.append(chunk)
            }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch {
            Log.inputSource.error("input source worker launch failed operation=\(arguments.first ?? "none") error=\(error)")
            return nil
        }
        guard ended.wait(timeout: deadline) == .success else {
            process.terminate()
            if ended.wait(timeout: .now() + 0.2) != .success { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            Log.inputSource.error("input source worker timed out operation=\(arguments.first ?? "none") timeout=\(timeout)")
            return nil
        }
        // A child that inherited stdout can keep the pipe open after the worker exits.
        // Wait for end of output only until the same deadline, then use what arrived.
        if output.finished.wait(timeout: max(deadline, .now() + 0.05)) != .success {
            Log.inputSource.error("input source worker output still open after exit operation=\(arguments.first ?? "none")")
        }
        return (process.terminationStatus, output.value)
    }
}
