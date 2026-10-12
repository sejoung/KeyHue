import AppKit
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
    private let handler: TerminalKeyPostHandler

    init(url: URL = TerminalKeyPost.socketURL(), handler: TerminalKeyPostHandler = TerminalKeyPostHandler()) {
        self.url = url
        self.handler = handler
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
        guard let listener = TerminalKeyPost.makeSocket() else { return }
        let bound = TerminalKeyPost.withAddress(path) { bind(listener, $0, $1) }
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
        // The input method stops waiting after `replyTimeout`; a late reply must not end KeyHue.
        TerminalKeyPost.preventSIGPIPE(connection)
        Self.setTimeouts(connection)
        let reply = handle(connection)
        Log.app.notice("terminal key posting: \(reply.rawValue)")
        if !TerminalKeyPost.write(TerminalKeyPost.encode(reply), to: connection) {
            Log.app.notice("terminal key posting: the input method stopped waiting for the reply")
        }
    }

    private func handle(_ connection: Int32) -> TerminalKeyPost.Reply {
        guard let requirement, Self.sender(of: connection, satisfies: requirement) else { return .untrusted }
        guard let request = TerminalKeyPost.request(from: Self.readLine(connection)) else { return .invalid }
        return handler.handle(request)
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
        TerminalKeyPost.setTimeouts(socket, send: TerminalKeyPost.timeout, receive: TerminalKeyPost.timeout)
    }

    /// One line, at most 512 bytes; a request is far shorter.
    static func readLine(_ socket: Int32) -> Data {
        TerminalKeyPost.readLine(socket, limit: 512)
    }
}
