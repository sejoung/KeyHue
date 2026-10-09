import CoreGraphics
import Foundation
import KeyHueCore

/// ADR 0073: asks the KeyHue utility to post a terminal fix's Backspace keys.
/// Synchronous on the main thread, bounded by `TerminalKeyPost.timeout` to send and
/// `TerminalKeyPost.replyTimeout` for the reply: the utility posts and replies without
/// waiting on this process, and the posted keys reach this input method only after
/// the current main-thread turn.
enum TerminalKeyPostClient {
    enum Delivery: Equatable {
        case posted
        /// Neither KeyHue nor this input method may post keys.
        case noPermission
        /// KeyHue refused (another app in front, secure input, ...); nothing was typed.
        case refused
    }

    /// KeyHue posts the keys, so this input method needs no Accessibility access.
    /// Only the process and the count are sent. Without KeyHue running, an input
    /// method allowed before ADR 0073 still posts them itself.
    static func backspaces(_ count: Int, to pid: pid_t) -> Delivery {
        let exchange = send(TerminalKeyPost.Request(pid: pid, backspaces: count))
        let step = TerminalKeyPost.clientStep(after: exchange, canPostItself: exchange == .unreachable && CGPreflightPostEventAccess())
        switch step {
        case .awaitKeys:
            // Unanswered: KeyHue may still post them. The delivery check sees whether they arrive (ADR 0083).
            SpikeLog.notice("shortcut correction keys requested via=utility count=\(count) answered=\(exchange != .unanswered)")
            return .posted
        case .postItself:
            postBackspaces(count, to: pid)
            SpikeLog.notice("shortcut correction keys requested via=self count=\(count)")
            return .posted
        case .noPermission:
            SpikeLog.notice("shortcut correction keys refused reply=\(describe(exchange))")
            return .noPermission
        case .refused:
            SpikeLog.notice("shortcut correction keys refused reply=\(describe(exchange))")
            return .refused
        }
    }

    private static func describe(_ exchange: TerminalKeyPost.Exchange) -> String {
        switch exchange {
        case .unreachable: "unavailable"
        case .unanswered: "unanswered"
        case let .replied(reply): reply.rawValue
        }
    }

    private static func postBackspaces(_ count: Int, to pid: pid_t) {
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

    /// `.unreachable` until the request is fully sent; after that, any missing reply is `.unanswered`.
    static func send(_ request: TerminalKeyPost.Request) -> TerminalKeyPost.Exchange {
        let path = TerminalKeyPost.socketURL().path
        guard path.utf8.count <= TerminalKeyPost.maximumSocketPathLength else { return .unreachable }
        let connection = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { return .unreachable }
        defer { close(connection) }
        var sendTimeout = timeval(TerminalKeyPost.timeout)
        var replyTimeout = timeval(TerminalKeyPost.replyTimeout)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, size)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &replyTimeout, size)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .unreachable }
        let data = TerminalKeyPost.encode(request)
        let written = data.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        guard written == data.count else { return .unreachable }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 128)
        while reply.count < 256, !reply.contains(0x0A) {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return TerminalKeyPost.reply(from: reply).map { .replied($0) } ?? .unanswered
    }
}

private extension timeval {
    init(_ interval: TimeInterval) {
        let seconds = interval.rounded(.down)
        self.init(tv_sec: Int(seconds), tv_usec: Int32((interval - seconds) * 1_000_000))
    }
}
