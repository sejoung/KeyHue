import Foundation
import KeyHueCore

/// Runs a short-lived process with a deadline: KeyHue's own worker modes
/// (`WorkerCommand`) and system tools (`codesign`, `tccutil`). Every run blocks
/// its thread up to the deadline, so the app's main thread uses `inBackground`.
enum ProcessRunner {
    /// Collects stdout while the worker runs, so output larger than the pipe
    /// buffer cannot block the worker until the timeout.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        let finished = DispatchSemaphore(value: 0)
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// nil when it could not start or did not finish in time (it is then stopped).
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 2) -> (status: Int32, output: Data)? {
        let process = Process()
        let pipe = Pipe()
        let output = Output()
        let ended = DispatchSemaphore(value: 0)
        let deadline = DispatchTime.now() + timeout
        let name = arguments.first.map { executable.lastPathComponent + " " + $0 } ?? executable.lastPathComponent
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
            Log.inputSource.error("process launch failed operation=\(name) error=\(error)")
            return nil
        }
        guard ended.wait(timeout: deadline) == .success else {
            process.terminate()
            if ended.wait(timeout: .now() + TerminalKeyPost.workerStopGrace) != .success { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            Log.inputSource.error("process timed out operation=\(name) timeout=\(timeout)")
            return nil
        }
        // A child that inherited stdout can keep the pipe open after the worker exits.
        // Wait for end of output only until the same deadline, then use what arrived.
        if output.finished.wait(timeout: max(deadline, .now() + 0.05)) != .success {
            Log.inputSource.error("process output still open after exit operation=\(name)")
        }
        return (process.terminationStatus, output.value)
    }

    /// A worker mode of this KeyHue executable (ADR 0053), in a fresh process.
    static func runSelf(_ arguments: [String], timeout: TimeInterval = 2) -> (status: Int32, output: Data)? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return run(executable: executable, arguments: arguments, timeout: timeout)
    }

    /// Runs blocking work (a process, a TIS snapshot from one) off the main thread.
    static func inBackground<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}
