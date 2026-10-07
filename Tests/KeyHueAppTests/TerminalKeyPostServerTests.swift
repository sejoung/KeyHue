import Foundation
import Testing
@testable import KeyHueApp

/// ADR 0073: the server reads one request line from the input method. The request
/// itself is decided by `TerminalKeyPost` (KeyHueCore); this is the socket read.
@Suite("Terminal key post server")
struct TerminalKeyPostServerTests {
    /// A connected socket pair; `send` is written and its end closed when `close` is true.
    private func line(after send: Data, closing close: Bool = true) -> Data {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { Darwin.close(pair[0]) }
        _ = send.withUnsafeBytes { write(pair[1], $0.baseAddress, $0.count) }
        if close { Darwin.close(pair[1]) } else { TerminalKeyPostServer.setTimeouts(pair[0]) }
        defer { if !close { Darwin.close(pair[1]) } }
        return TerminalKeyPostServer.readLine(pair[0])
    }

    @Test func readsOneRequestLine() {
        #expect(line(after: Data("v1 123 4\n".utf8)) == Data("v1 123 4\n".utf8))
    }

    /// A sender that stops without a newline gets what it sent, which the request
    /// parser then rejects; it never blocks past the timeout.
    @Test func endsAtTheEndOfTheConnectionOrTheTimeout() {
        #expect(line(after: Data("v1 123".utf8)) == Data("v1 123".utf8))
        #expect(line(after: Data("v1 123".utf8), closing: false) == Data("v1 123".utf8))
        #expect(line(after: Data()).isEmpty)
    }

    /// A long line without a newline is cut at 512 bytes: a request is far shorter.
    @Test func neverReadsMoreThan512Bytes() {
        #expect(line(after: Data(repeating: 0x41, count: 4096)).count == 512)
    }
}
