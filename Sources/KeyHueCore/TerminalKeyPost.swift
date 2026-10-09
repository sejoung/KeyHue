import Foundation

/// ADR 0073: the input method fixes a terminal word by erasing it with Backspace
/// keys. The utility, which already has Accessibility access, posts those keys so
/// the input method needs no permission of its own. Only a process ID and a count
/// cross the boundary: never text, words or app contents.
public enum TerminalKeyPost {
    /// The input method's code identifier; the utility accepts requests only from it.
    public static let inputMethodIdentifier = InputMethodIntegration.bundleID
    /// Marks the posted keys. Diagnostics only: the input method recognizes them by count.
    public static let postedKeyMarker: Int64 = 0x4B48_5545 // "KHUE"
    public static let maximumBackspaces = 256
    /// Each connection gets this long to connect and send its request.
    public static let timeout: TimeInterval = 0.5
    /// The utility's worker process for a permission allowed after launch (ADR 0077).
    public static let workerTimeout: TimeInterval = 1
    /// The worker is stopped up to this long after `workerTimeout` before the utility replies.
    public static let workerStopGrace: TimeInterval = 0.2
    /// How long the input method waits for the reply. Longer than the utility can take,
    /// so a slow worker is not mistaken for a missing KeyHue (ADR 0083).
    public static let replyTimeout: TimeInterval = 1.5
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminator.
    public static let maximumSocketPathLength = 103

    public struct Request: Codable, Equatable, Sendable {
        public let pid: Int32
        public let backspaces: Int

        public init(pid: Int32, backspaces: Int) {
            self.pid = pid
            self.backspaces = backspaces
        }
    }

    public enum Reply: String, Codable, Equatable, Sendable {
        case posted
        /// The process is not the front app any more.
        case notFront
        /// The utility has no Accessibility (event posting) access.
        case noPermission
        /// A password field holds secure input; nothing is typed into it.
        case secureInput
        /// Malformed request or a count outside 1...maximumBackspaces.
        case invalid
        /// The sender is not this KeyHue's input method.
        case untrusted
    }

    /// How a request ended for the input method.
    public enum Exchange: Equatable, Sendable {
        /// No KeyHue listening: nothing was sent.
        case unreachable
        /// The request was sent but no reply came. KeyHue may still post the keys.
        case unanswered
        case replied(Reply)
    }

    /// What the input method does next.
    public enum ClientStep: Equatable, Sendable {
        /// Wait for the keys: the delivery check inserts the fix or gives up.
        case awaitKeys
        /// KeyHue is not running: post the keys itself (an input method allowed before ADR 0073).
        case postItself
        case noPermission
        /// Nothing was typed.
        case refused
    }

    /// ADR 0083: posting after an unanswered request could erase the word twice.
    public static func clientStep(after exchange: Exchange, canPostItself: Bool) -> ClientStep {
        switch exchange {
        case .replied(.posted), .unanswered: return .awaitKeys
        case .unreachable: return canPostItself ? .postItself : .noPermission
        case .replied(.noPermission): return .noPermission
        case .replied: return .refused
        }
    }

    /// What the utility does with a request from the verified input method.
    public static func decide(_ request: Request, frontPID: Int32?, secureInput: Bool, canPost: Bool) -> Reply {
        guard request.pid > 0, (1...maximumBackspaces).contains(request.backspaces) else { return .invalid }
        guard let frontPID, frontPID == request.pid else { return .notFront }
        if secureInput { return .secureInput }
        guard canPost else { return .noPermission }
        return .posted
    }

    // MARK: wire format: one JSON object per line

    public static func encode(_ request: Request) -> Data { line(request) }
    public static func encode(_ reply: Reply) -> Data { line(["reply": reply]) }

    public static func request(from data: Data) -> Request? {
        try? JSONDecoder().decode(Request.self, from: trimmed(data))
    }

    public static func reply(from data: Data) -> Reply? {
        (try? JSONDecoder().decode([String: Reply].self, from: trimmed(data)))?["reply"]
    }

    private static func line<T: Encodable>(_ value: T) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func trimmed(_ data: Data) -> Data {
        guard let end = data.firstIndex(of: 0x0A) else { return data }
        return data[data.startIndex..<end]
    }

    // MARK: channel

    public static func socketURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/KeyHue", isDirectory: true)
            .appendingPathComponent("terminal-keys.sock")
    }

    /// The input method signed with the utility's own leaf certificate. nil for an
    /// ad-hoc signed utility: without a certificate nothing can be required, so the
    /// utility does not serve requests at all.
    public static func senderRequirement(certificateLeafSHA1 hex: String?) -> String? {
        guard let hex, hex.count == 40, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "identifier \"\(inputMethodIdentifier)\" and certificate leaf = H\"\(hex.lowercased())\""
    }
}
