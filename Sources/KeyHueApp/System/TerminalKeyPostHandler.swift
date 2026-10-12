import AppKit
import Carbon
import KeyHueCore

/// What posting a terminal fix needs from the system. Tests replace it.
protocol KeyPostingEnvironment: Sendable {
    /// The front app, secure input and this process's posting permission, read now.
    func state() -> (frontPID: Int32?, secureInput: Bool, canPost: Bool)
    func postBackspaces(_ count: Int, to pid: Int32)
    /// ADR 0077: a new KeyHue process posts them. true when it did.
    func postFromNewProcess(_ request: TerminalKeyPost.Request) -> Bool
    /// The system's request, which lists KeyHue in System Settings.
    func requestPermission()
}

/// ADR 0073: one verified request from the input method, decided by `TerminalKeyPost`
/// and carried out here. Socket I/O and sender verification stay in the server.
/// Used only from the server's serial queue.
final class TerminalKeyPostHandler: @unchecked Sendable {
    private let environment: KeyPostingEnvironment
    /// macOS asks once per process; KeyHue is not listed for Accessibility until it
    /// asks, because it no longer checks the permission it does not use (ADR 0075).
    private var askedForPermission = false

    init(environment: KeyPostingEnvironment = SystemKeyPostingEnvironment()) {
        self.environment = environment
    }

    func handle(_ request: TerminalKeyPost.Request) -> TerminalKeyPost.Reply {
        let state = environment.state()
        let reply = TerminalKeyPost.decide(request, frontPID: state.frontPID, secureInput: state.secureInput, canPost: state.canPost)
        switch reply {
        case .posted:
            environment.postBackspaces(request.backspaces, to: request.pid)
            return .posted
        case .noPermission:
            // This process keeps macOS's first answer until it restarts. A permission the
            // user just allowed is seen by a new process (ADR 0077).
            if environment.postFromNewProcess(request) {
                Log.app.notice("terminal key posting: allowed since launch; posted from a new process")
                return .posted
            }
            if !askedForPermission {
                askedForPermission = true
                environment.requestPermission()
            }
            return .noPermission
        default:
            return reply
        }
    }
}

/// AppKit state is read on the main thread; the server's queue waits for it.
struct SystemKeyPostingEnvironment: KeyPostingEnvironment {
    func state() -> (frontPID: Int32?, secureInput: Bool, canPost: Bool) {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                (NSWorkspace.shared.frontmostApplication?.processIdentifier, IsSecureEventInputEnabled(), CGPreflightPostEventAccess())
            }
        }
    }

    func postBackspaces(_ count: Int, to pid: Int32) {
        TerminalKeyPost.postBackspaces(count, to: pid)
    }

    func postFromNewProcess(_ request: TerminalKeyPost.Request) -> Bool {
        ProcessRunner.runSelf([WorkerCommand.postBackspacesFlag, String(request.pid), String(request.backspaces)],
                              timeout: TerminalKeyPost.workerTimeout)?.status == 0
    }

    func requestPermission() {
        DispatchQueue.main.sync { _ = CGRequestPostEventAccess() }
    }
}
