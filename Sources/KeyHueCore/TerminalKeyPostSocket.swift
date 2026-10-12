import CoreGraphics
import Foundation

/// The socket and key plumbing both ends of `TerminalKeyPost` share: the utility
/// serves it, the input method connects to it (ADR 0073).
extension TerminalKeyPost {
    /// A Unix stream socket that never raises SIGPIPE. Either end may close first
    /// (a timeout, a quit); a write to it then fails with EPIPE instead of ending
    /// this process.
    public static func makeSocket() -> Int32? {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        preventSIGPIPE(socket)
        return socket
    }

    /// Accepted sockets get it too: the option is per socket.
    public static func preventSIGPIPE(_ socket: Int32) {
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func setTimeouts(_ socket: Int32, send: TimeInterval, receive: TimeInterval) {
        var send = timeval(interval: send)
        var receive = timeval(interval: receive)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &send, size)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &receive, size)
    }

    /// `path` must fit `maximumSocketPathLength`.
    public static func withAddress<Result>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix(maximumSocketPathLength)) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// One line, at most `limit` bytes; requests and replies are far shorter.
    public static func readLine(_ socket: Int32, limit: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while data.count < limit, !data.contains(0x0A) {
            let count = read(socket, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// Writes all of `data`. false when the peer is gone or the send timed out.
    @discardableResult
    public static func write(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) } == data.count
    }

    /// Plain Backspace keys to that process only, marked as KeyHue's.
    public static func postBackspaces(_ count: Int, to pid: Int32) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.delete, keyDown: down) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: postedKeyMarker)
                event.postToPid(pid)
            }
        }
    }
}

extension timeval {
    /// Whole seconds in `tv_sec`: `tv_usec` must stay below one second.
    init(interval: TimeInterval) {
        let seconds = max(0, interval).rounded(.down)
        self.init(tv_sec: Int(seconds), tv_usec: Int32((max(0, interval) - seconds) * 1_000_000))
    }
}
