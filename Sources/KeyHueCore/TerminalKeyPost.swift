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
    /// Each connection gets this long to send its request and read the reply.
    public static let timeout: TimeInterval = 0.5
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
