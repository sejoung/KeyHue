import Foundation
import Testing
@testable import KeyHueCore

/// ADR 0073: the utility posts a terminal fix's Backspace keys for the input method.
struct TerminalKeyPostTests {
    private let request = TerminalKeyPost.Request(pid: 1514, backspaces: 6)

    @Test func postsOnlyForTheFrontProcessWithPermission() {
        #expect(TerminalKeyPost.decide(request, frontPID: 1514, secureInput: false, canPost: true) == .posted)
    }

    @Test func anotherFrontAppIsNotTypedInto() {
        #expect(TerminalKeyPost.decide(request, frontPID: 427, secureInput: false, canPost: true) == .notFront)
        #expect(TerminalKeyPost.decide(request, frontPID: nil, secureInput: false, canPost: true) == .notFront)
    }

    @Test func aPasswordPromptIsNeverTypedInto() {
        #expect(TerminalKeyPost.decide(request, frontPID: 1514, secureInput: true, canPost: true) == .secureInput)
    }

    @Test func withoutAccessibilityNothingIsPosted() {
        #expect(TerminalKeyPost.decide(request, frontPID: 1514, secureInput: false, canPost: false) == .noPermission)
    }

    // MARK: input method side (ADR 0083)

    @Test func anUnansweredRequestIsNeverPostedAgain() {
        // KeyHue may still be posting from its worker: posting too would erase twice.
        #expect(TerminalKeyPost.clientStep(after: .unanswered, canPostItself: true) == .awaitKeys)
        #expect(TerminalKeyPost.clientStep(after: .unanswered, canPostItself: false) == .awaitKeys)
    }

    @Test func onlyAMissingKeyHueLetsTheInputMethodPostItself() {
        #expect(TerminalKeyPost.clientStep(after: .unreachable, canPostItself: true) == .postItself)
        #expect(TerminalKeyPost.clientStep(after: .unreachable, canPostItself: false) == .noPermission)
        #expect(TerminalKeyPost.clientStep(after: .replied(.posted), canPostItself: true) == .awaitKeys)
        #expect(TerminalKeyPost.clientStep(after: .replied(.noPermission), canPostItself: true) == .noPermission)
        for reply in [TerminalKeyPost.Reply.notFront, .secureInput, .invalid, .untrusted] {
            #expect(TerminalKeyPost.clientStep(after: .replied(reply), canPostItself: true) == .refused)
        }
    }

    @Test func theInputMethodWaitsLongerThanKeyHueCanTake() {
        // A worker that takes its full time and is then stopped still answers in time.
        #expect(TerminalKeyPost.workerTimeout + TerminalKeyPost.workerStopGrace < TerminalKeyPost.replyTimeout)
    }

    @Test(arguments: [0, -1, TerminalKeyPost.maximumBackspaces + 1])
    func countsOutsideTheLimitAreInvalid(_ count: Int) {
        let request = TerminalKeyPost.Request(pid: 1514, backspaces: count)
        #expect(TerminalKeyPost.decide(request, frontPID: 1514, secureInput: false, canPost: true) == .invalid)
    }

    @Test func aMissingProcessIsInvalid() {
        let request = TerminalKeyPost.Request(pid: 0, backspaces: 1)
        #expect(TerminalKeyPost.decide(request, frontPID: 0, secureInput: false, canPost: true) == .invalid)
    }

    @Test func requestAndReplyRoundTripAsOneLine() throws {
        let data = TerminalKeyPost.encode(request)
        #expect(data.last == 0x0A)
        #expect(data.dropLast().contains(0x0A) == false)
        #expect(TerminalKeyPost.request(from: data) == request)
        for reply in [TerminalKeyPost.Reply.posted, .notFront, .noPermission, .secureInput, .invalid, .untrusted] {
            #expect(TerminalKeyPost.reply(from: TerminalKeyPost.encode(reply)) == reply)
        }
    }

    /// Only a process and a count: no text crosses the boundary.
    @Test func theRequestCarriesNoText() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: TerminalKeyPost.encode(request)) as? [String: Any])
        #expect(Set(object.keys) == ["pid", "backspaces"])
    }

    @Test(arguments: ["", "{}", "{\"pid\":\"x\",\"backspaces\":1}", "not json"])
    func malformedRequestsAreRejected(_ text: String) {
        #expect(TerminalKeyPost.request(from: Data(text.utf8)) == nil)
    }

    @Test func malformedRepliesAreRejected() {
        #expect(TerminalKeyPost.reply(from: Data("{\"reply\":\"maybe\"}".utf8)) == nil)
        #expect(TerminalKeyPost.reply(from: Data()) == nil)
    }

    @Test func theSenderMustBeTheInputMethodWithTheSameCertificate() {
        let hex = String(repeating: "AB", count: 20)
        #expect(TerminalKeyPost.senderRequirement(certificateLeafSHA1: hex)
            == "identifier \"io.github.sejoung.keyhue.inputmethod.spike\" and certificate leaf = H\"\(hex.lowercased())\"")
    }

    /// Ad-hoc signed: nothing to require, so nothing is served.
    @Test(arguments: [Optional<String>.none, "", "abc", String(repeating: "zz", count: 20)])
    func withoutACertificateThereIsNoRequirement(_ hex: String?) {
        #expect(TerminalKeyPost.senderRequirement(certificateLeafSHA1: hex) == nil)
    }

    @Test func theSocketPathFitsAUnixSocketAddress() {
        let url = TerminalKeyPost.socketURL(home: URL(fileURLWithPath: "/Users/someone.with.a.longer.name"))
        #expect(url.path.hasSuffix("Library/Application Support/KeyHue/terminal-keys.sock"))
        #expect(url.path.utf8.count <= TerminalKeyPost.maximumSocketPathLength)
    }
}
