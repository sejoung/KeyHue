import CoreGraphics
import Foundation
import KeyHueCore
import KeyHueInputMethodSpikeCore

/// ADR 0073: asks the KeyHue utility to post a terminal fix's Backspace keys.
/// Blocking, bounded by `TerminalKeyPost.timeout` to send and
/// `TerminalKeyPost.replyTimeout` for the reply: call it off the main thread. The
/// utility posts and replies without waiting on this process.
enum TerminalKeyPostClient {
    /// KeyHue posts the keys, so this input method needs no Accessibility access.
    /// Only the process and the count are sent. Without KeyHue running, an input
    /// method allowed before ADR 0073 still posts them itself.
    static func backspaces(_ count: Int, to pid: pid_t) -> TerminalKeyDelivery {
        let exchange = send(TerminalKeyPost.Request(pid: pid, backspaces: count))
        let step = TerminalKeyPost.clientStep(after: exchange, canPostItself: exchange == .unreachable && CGPreflightPostEventAccess())
        switch step {
        case .awaitKeys:
            // Unanswered: KeyHue may still post them. The delivery check sees whether they arrive (ADR 0083).
            SpikeLog.notice("shortcut correction keys requested via=utility count=\(count) answered=\(exchange != .unanswered)")
            return .posted
        case .postItself:
            TerminalKeyPost.postBackspaces(count, to: pid)
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

    /// `.unreachable` until the request is fully sent; after that, any missing reply is `.unanswered`.
    static func send(_ request: TerminalKeyPost.Request) -> TerminalKeyPost.Exchange {
        let path = TerminalKeyPost.socketURL().path
        guard path.utf8.count <= TerminalKeyPost.maximumSocketPathLength else { return .unreachable }
        // No SIGPIPE: KeyHue may quit or close the connection while this input method writes.
        guard let connection = TerminalKeyPost.makeSocket() else { return .unreachable }
        defer { close(connection) }
        TerminalKeyPost.setTimeouts(connection, send: TerminalKeyPost.timeout, receive: TerminalKeyPost.replyTimeout)
        guard TerminalKeyPost.withAddress(path, { connect(connection, $0, $1) }) == 0,
              TerminalKeyPost.write(TerminalKeyPost.encode(request), to: connection) else { return .unreachable }
        let reply = TerminalKeyPost.readLine(connection, limit: 256)
        return TerminalKeyPost.reply(from: reply).map { .replied($0) } ?? .unanswered
    }
}
