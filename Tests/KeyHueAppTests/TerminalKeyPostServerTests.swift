import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

/// ADR 0073: the server reads one request line from the input method. The request
/// itself is decided by `TerminalKeyPost` (KeyHueCore); this is the socket read.
@Suite("Terminal key post server")
struct TerminalKeyPostServerTests {
    /// Start on MainActor just like InputSwitching, then exercise the actual
    /// dispatch source on its background queue. A certificate no sender owns
    /// keeps this test from posting keys or needing system permissions.
    @Test @MainActor func servesAndStopsOnItsBackgroundQueue() async throws {
        let directory = URL(fileURLWithPath: "/tmp/kh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("keys.sock")
        let server = TerminalKeyPostServer(url: url, certificateLeafSHA1: { String(repeating: "0", count: 40) })
        defer { server.stop() }

        for _ in 0..<2 {
            server.start()
            #expect(FileManager.default.fileExists(atPath: url.path))
            let reply = try await Task.detached {
                let socket = try #require(TerminalKeyPost.makeSocket())
                defer { Darwin.close(socket) }
                TerminalKeyPostServer.setTimeouts(socket)
                let connected = TerminalKeyPost.withAddress(url.path) { connect(socket, $0, $1) }
                #expect(connected == 0)
                // The untrusted sender is rejected before any request is read.
                return TerminalKeyPost.reply(from: TerminalKeyPostServer.readLine(socket))
            }.value
            #expect(reply == .untrusted)
            server.stop()
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

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

/// Records what the handler asks the system to do.
private final class FakeKeyPostingEnvironment: KeyPostingEnvironment, @unchecked Sendable {
    var frontPID: Int32? = 1514
    var secureInput = false
    var canPost = true
    var newProcessPosts = false
    private(set) var events: [String] = []
    func state() -> (frontPID: Int32?, secureInput: Bool, canPost: Bool) { (frontPID, secureInput, canPost) }
    func postBackspaces(_ count: Int, to pid: Int32) { events.append("post \(count) to \(pid)") }
    func postFromNewProcess(_ request: TerminalKeyPost.Request) -> Bool {
        events.append("worker \(request.backspaces)")
        return newProcessPosts
    }
    func requestPermission() { events.append("request") }
}

/// ADR 0073, 0077: what one verified request does.
@Suite("Terminal key post handler")
struct TerminalKeyPostHandlerTests {
    private let request = TerminalKeyPost.Request(pid: 1514, backspaces: 6)

    @Test func postsOnlyForTheFrontProcess() {
        let environment = FakeKeyPostingEnvironment()
        let handler = TerminalKeyPostHandler(environment: environment)
        #expect(handler.handle(request) == .posted)
        environment.frontPID = 427
        #expect(handler.handle(request) == .notFront)
        #expect(environment.events == ["post 6 to 1514"])
    }

    /// Allowed since launch: a new process sees it and posts, once.
    @Test func aPermissionAllowedSinceLaunchPostsFromANewProcess() {
        let environment = FakeKeyPostingEnvironment()
        environment.canPost = false
        environment.newProcessPosts = true
        #expect(TerminalKeyPostHandler(environment: environment).handle(request) == .posted)
        #expect(environment.events == ["worker 6"])
    }

    /// Not allowed at all: macOS is asked once per process, never twice.
    @Test func withoutPermissionMacOSIsAskedOnce() {
        let environment = FakeKeyPostingEnvironment()
        environment.canPost = false
        let handler = TerminalKeyPostHandler(environment: environment)
        #expect(handler.handle(request) == .noPermission)
        #expect(handler.handle(request) == .noPermission)
        #expect(environment.events == ["worker 6", "request", "worker 6"])
    }

    @Test func aPasswordPromptIsNeverTypedInto() {
        let environment = FakeKeyPostingEnvironment()
        environment.secureInput = true
        #expect(TerminalKeyPostHandler(environment: environment).handle(request) == .secureInput)
        #expect(environment.events.isEmpty)
    }
}
