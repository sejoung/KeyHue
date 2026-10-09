import AppKit
import Carbon
import CryptoKit
import KeyHueCore
import Security

/// ADR 0073: posts a terminal fix's Backspace keys for the input method, which
/// then needs no Accessibility access of its own. Requests come over a Unix socket
/// only this user can open, and every connection must come from the input method
/// signed with this app's certificate. A request is a process ID and a count.
final class TerminalKeyPostServer: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "io.github.sejoung.keyhue.terminal-keys")
    private var source: DispatchSourceRead?
    private var requirement: SecRequirement?

    init(url: URL = TerminalKeyPost.socketURL()) {
        self.url = url
    }

    @MainActor
    func start() {
        guard source == nil else { return }
        guard let text = TerminalKeyPost.senderRequirement(certificateLeafSHA1: Self.ownCertificateLeafSHA1()) else {
            Log.app.notice("terminal key posting not served: this build has no signing certificate")
            return
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            Log.app.error("terminal key posting not served: invalid sender requirement")
            return
        }
        let path = url.path
        guard path.utf8.count <= TerminalKeyPost.maximumSocketPathLength else {
            Log.app.error("terminal key posting not served: socket path too long")
            return
        }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only this user may reach the socket: the folder, then the socket itself.
        guard chmod(directory.path, 0o700) == 0 else {
            Log.app.error("terminal key posting not served: folder permissions (errno \(errno))")
            return
        }
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            Log.app.error("terminal key posting not served: socket setup failed (errno \(errno))")
            close(listener)
            unlink(path)
            return
        }
        self.requirement = requirement
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(listener) }
        source.setCancelHandler { close(listener) }
        source.resume()
        self.source = source
        Log.app.notice("terminal key posting served")
    }

    @MainActor
    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        unlink(url.path)
    }

    // MARK: connections (on `queue`)

    private func acceptOne(_ listener: Int32) {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { close(connection) }
        let flags = fcntl(connection, F_GETFL)
        _ = fcntl(connection, F_SETFL, flags & ~O_NONBLOCK)
        Self.setTimeouts(connection)
        let reply = handle(connection)
        Log.app.notice("terminal key posting: \(reply.rawValue)")
        let data = TerminalKeyPost.encode(reply)
        _ = data.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
    }

    private func handle(_ connection: Int32) -> TerminalKeyPost.Reply {
        guard let requirement, Self.sender(of: connection, satisfies: requirement) else { return .untrusted }
        guard let request = TerminalKeyPost.request(from: Self.readLine(connection)) else { return .invalid }
        return post(request)
    }

    /// macOS asks once per process; KeyHue is not listed for Accessibility until it
    /// asks, because it no longer checks the permission it does not use (ADR 0075).
    @MainActor private static var askedForPermission = false

    private func post(_ request: TerminalKeyPost.Request) -> TerminalKeyPost.Reply {
        let reply = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                TerminalKeyPost.decide(request, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                       secureInput: IsSecureEventInputEnabled(), canPost: CGPreflightPostEventAccess())
            }
        }
        switch reply {
        case .posted:
            Self.postBackspaces(request.backspaces, to: request.pid)
            return .posted
        case .noPermission:
            // This process keeps macOS's first answer until it restarts. A permission the
            // user just allowed is seen by a new process (ADR 0077).
            if let executable = Bundle.main.executableURL,
               let result = InputSourceWorker.run(executable: executable, arguments: [
                   WorkerCommand.postBackspacesFlag, String(request.pid), String(request.backspaces)], timeout: TerminalKeyPost.workerTimeout),
               result.status == 0 {
                Log.app.notice("terminal key posting: allowed since launch; posted from a new process")
                return .posted
            }
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    if !Self.askedForPermission {
                        Self.askedForPermission = true
                        _ = CGRequestPostEventAccess()
                    }
                }
            }
            return .noPermission
        default:
            return reply
        }
    }

    /// Plain Backspace keys to that process only, as the input method posted them before ADR 0073.
    static func postBackspaces(_ count: Int, to pid: Int32) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: TerminalKeyPost.postedKeyMarker)
                event.postToPid(pid)
            }
        }
    }

    // MARK: sender verification

    /// The connecting process, identified by its audit token (not its PID, which can be reused).
    private static func sender(of connection: Int32, satisfies requirement: SecRequirement) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// SHA-1 of this app's leaf signing certificate, as a code requirement names it.
    static func ownCertificateLeafSHA1() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: I/O

    static func setTimeouts(_ socket: Int32) {
        var timeout = timeval(tv_sec: 0, tv_usec: Int32(TerminalKeyPost.timeout * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    /// One line, at most 512 bytes; a request is far shorter.
    static func readLine(_ socket: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while data.count < 512, !data.contains(0x0A) {
            let count = read(socket, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}
