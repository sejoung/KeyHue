import Foundation
import KeyHueCore
import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0067, 0068, 0071, 0073: the shortcut fix's steps, driven by a fake clock,
/// a fake key poster and a fake client. Nothing waits on the real clock.
@Suite("Shortcut corrector")
struct ShortcutCorrectorTests {
    final class Scheduler: CorrectionScheduling {
        var now = 0.0
        private var queue: [(due: Double, order: Int, work: () -> Void)] = []
        private var count = 0

        func schedule(after delay: Double, _ work: @escaping () -> Void) {
            queue.append((now + delay, count, work))
            count += 1
        }

        /// Runs what falls due within `seconds`, in order, on the clock it was due.
        func advance(by seconds: Double) {
            let end = now + seconds
            while let next = queue.indices.filter({ queue[$0].due <= end })
                .min(by: { (queue[$0].due, queue[$0].order) < (queue[$1].due, queue[$1].order) }) {
                let item = queue.remove(at: next)
                now = max(now, item.due)
                item.work()
            }
            now = end
        }
    }

    final class Keys: TerminalKeyPosting {
        var front: (bundleID: String?, pid: pid_t)? = (ShortcutCorrectorTests.terminal, 42)
        var modifiersHeld = false
        var requests: [(count: Int, pid: pid_t)] = []
        private var completions: [(TerminalKeyDelivery) -> Void] = []

        func frontApp() -> (bundleID: String?, pid: pid_t)? { front }

        func requestBackspaces(_ count: Int, to pid: pid_t, completion: @escaping (TerminalKeyDelivery) -> Void) {
            requests.append((count, pid))
            completions.append(completion)
        }

        func reply(_ delivery: TerminalKeyDelivery) {
            completions.removeFirst()(delivery)
        }
    }

    /// A client over a document. Terminals report no text: `reportsText == false`.
    final class Client: ShortcutCorrectionClient {
        let bundleID: String?
        var document = ""
        var selection = NSRange(location: NSNotFound, length: 0)
        var hasMarkedText = false
        var inserts: [String] = []
        var modes: [ProbeSession.Mode] = []

        init(bundleID: String?) { self.bundleID = bundleID }

        func text(in range: NSRange) -> String? {
            guard bundleID != ShortcutCorrectorTests.terminal, range.location >= 0, NSMaxRange(range) <= document.utf16.count else { return nil }
            return (document as NSString).substring(with: range)
        }

        func replace(_ range: NSRange, with text: String) {
            document = (document as NSString).replacingCharacters(in: range, with: text)
            selection = NSRange(location: range.location + text.utf16.count, length: 0)
        }

        func insert(_ text: String) { inserts.append(text) }
        func select(_ mode: ProbeSession.Mode) { modes.append(mode) }
    }

    static let terminal = "com.apple.Terminal"

    private final class Recorder {
        var events: [ShortcutCorrector.Event] = []
    }

    let scheduler = Scheduler()
    let keys = Keys()
    let client = Client(bundleID: terminal)
    let corrector: ShortcutCorrector
    private let recorder: Recorder

    var events: [ShortcutCorrector.Event] { recorder.events }

    init() {
        let recorder = Recorder()
        self.recorder = recorder
        corrector = ShortcutCorrector(scheduler: scheduler, keys: keys) { recorder.events.append($0) }
    }

    /// Letters and Spaces as the session routes them, typed in `mode`.
    private func type(_ text: String, mode: ProbeSession.Mode = .latin) {
        for character in text {
            let route: InputRoute = character == " " ? .commitSpace : .compose(character)
            corrector.key(route, keyCode: 0, modifiers: false, text: String(character), composing: false,
                          clientID: client.bundleID, mode: mode)
        }
    }

    private func request(mode: ProbeSession.Mode = .latin, isCurrent: @escaping () -> Bool = { true }) {
        corrector.request(client: client, mode: mode, isCurrent: isCurrent)
    }

    /// Every posted Backspace comes back through the input method.
    private func deliverBackspaces(_ count: Int) {
        for _ in 0..<count {
            #expect(corrector.postedKeyArrived(isBackspace: true, markerSeen: true))
        }
        scheduler.advance(by: 0)
    }

    // MARK: terminals

    @Test func theTypedWordIsErasedWithKeysAndTheFixInsertedAfterTheLast() {
        type("dkssud ")
        request()
        #expect(keys.requests.isEmpty)
        scheduler.advance(by: ShortcutCorrector.interval)
        #expect(keys.requests.map(\.count) == [7])
        #expect(keys.requests.map(\.pid) == [42])
        // The mode is selected before the keys are posted (ADR 0073).
        #expect(client.modes == [.hangul])
        keys.reply(.posted)
        deliverBackspaces(7)
        #expect(client.inserts == ["안녕 "])
        #expect(events == [.keysDelivered(markerSeen: true), .correctedByKeys])
        // The user's own Backspace afterwards is not taken for one of ours.
        #expect(!corrector.postedKeyArrived(isBackspace: true, markerSeen: false))
    }

    @Test func theShortcutAgainRightAwayPutsTheOriginalBack() {
        type("dkssud ")
        request()
        scheduler.advance(by: ShortcutCorrector.interval)
        keys.reply(.posted)
        deliverBackspaces(7)
        request()
        scheduler.advance(by: ShortcutCorrector.interval)
        #expect(keys.requests.map(\.count) == [7, 3])
        keys.reply(.posted)
        deliverBackspaces(3)
        #expect(client.inserts == ["안녕 ", "dkssud "])
        #expect(client.modes == [.hangul, .latin])
        // An undo is not remembered: a third press fixes the restored word again.
        request()
        scheduler.advance(by: ShortcutCorrector.interval)
        #expect(keys.requests.map(\.count) == [7, 3, 7])
    }

    /// ADR 0071: people keep ⌥ down; the fix waits for it, up to its limit.
    @Test func heldModifiersDelayTheKeysUntilTheyExpire() {
        type("dkssud")
        keys.modifiersHeld = true
        request()
        scheduler.advance(by: ShortcutCorrector.modifierTimeout - 0.05)
        #expect(keys.requests.isEmpty)
        // ↩ tapped again with ⌥ still held is the same request.
        request()
        #expect(events == [.alreadyWaiting])
        scheduler.advance(by: 0.1)
        #expect(events == [.alreadyWaiting, .expired(modifiersHeld: true)])
        #expect(keys.requests.isEmpty)
        #expect(client.modes.isEmpty)
    }

    @Test func releasedModifiersLetTheKeysGo() {
        type("dkssud")
        keys.modifiersHeld = true
        request()
        scheduler.advance(by: 2)
        keys.modifiersHeld = false
        scheduler.advance(by: 0.05)
        #expect(keys.requests.map(\.count) == [6])
    }

    /// The client's own composition is finished first, for a shorter while.
    @Test func markedTextExpiresSooner() {
        type("dkssud")
        client.hasMarkedText = true
        request()
        scheduler.advance(by: ShortcutCorrector.keyTimeout + 0.05)
        #expect(events == [.expired(modifiersHeld: false)])
        #expect(keys.requests.isEmpty)
    }

    /// The user typed on while the fix waited: the fix is dropped, the key kept.
    @Test func aKeyWhileWaitingCancelsTheFix() {
        type("dkssud")
        keys.modifiersHeld = true
        request()
        type("a")
        keys.modifiersHeld = false
        scheduler.advance(by: 1)
        #expect(keys.requests.isEmpty)
        request()
        #expect(!events.contains(.alreadyWaiting))
    }

    @Test func anotherAppInFrontLosesTheContext() {
        type("dkssud")
        keys.front = ("com.apple.Safari", 7)
        request()
        scheduler.advance(by: ShortcutCorrector.interval)
        #expect(events == [.lostContext(byKeys: true)])
        #expect(keys.requests.isEmpty)
        // The word before the caret is unknown now.
        keys.front = (Self.terminal, 42)
        request()
        #expect(events.last == .failed(.nothingToFix, app: Self.terminal))
        #expect(events.contains(.noTypedWord(cleared: "context", keys: 0)))
    }

    @Test func refusedKeysRevertTheModeQuietly() {
        type("dkssud")
        request()
        scheduler.advance(by: ShortcutCorrector.interval)
        keys.reply(.refused)
        #expect(client.modes == [.hangul, .latin])
        #expect(client.inserts.isEmpty)
        #expect(events.isEmpty)
        #expect(!corrector.postedKeyArrived(isBackspace: true, markerSeen: true))
    }

    @Test func keysWithoutPermissionRevertAndReportIt() {
        type("dkssud")
        request()
        scheduler.advance(by: ShortcutCorrector.interval)
        keys.reply(.noPermission)
        #expect(client.modes == [.hangul, .latin])
        #expect(client.inserts.isEmpty)
        #expect(events == [.failed(.keyPermission, app: Self.terminal)])
    }

    /// Nothing was erased: the word stays as typed, in the mode it was typed in.
    @Test func keysThatNeverArriveRevertAndReportIt() {
        type("dkssud")
        request()
        scheduler.advance(by: ShortcutCorrector.interval)
        keys.reply(.posted)
        scheduler.advance(by: ShortcutCorrector.deliveryTimeout)
        #expect(events == [.keysNotDelivered(arrived: 0, of: 6), .failed(.replacementIgnored, app: Self.terminal)])
        #expect(client.modes == [.hangul, .latin])
        #expect(client.inserts.isEmpty)
        #expect(!corrector.postedKeyArrived(isBackspace: true, markerSeen: true))
    }

    /// Some characters are gone already: the fix is inserted rather than leave a fragment.
    @Test func keysThatPartlyArriveStillInsertTheFix() {
        type("dkssud")
        request()
        scheduler.advance(by: ShortcutCorrector.interval)
        keys.reply(.posted)
        #expect(corrector.postedKeyArrived(isBackspace: true, markerSeen: true))
        #expect(corrector.postedKeyArrived(isBackspace: true, markerSeen: true))
        scheduler.advance(by: ShortcutCorrector.deliveryTimeout)
        #expect(events == [.keysNotDelivered(arrived: 2, of: 6), .correctedByKeys])
        #expect(client.inserts == ["안녕"])
        #expect(client.modes == [.hangul])
    }

    /// ADR 0078: Shift+arrows select in a shell; the selection is not the typed word.
    @Test func aSelectionIsReportedAsSuch() {
        type("dkssud")
        corrector.key(.commitAndPass, keyCode: KeyCode.leftArrow, modifiers: false, shift: true, text: "\u{F702}",
                      composing: false, clientID: client.bundleID, mode: .latin)
        request()
        #expect(events == [.noTypedWord(cleared: "selection", keys: 0), .failed(.terminalSelection, app: Self.terminal)])
    }

    // MARK: clients that report text

    @Test func theWordBeforeTheCaretIsReplacedAndPutBack() {
        let editor = Client(bundleID: "com.apple.TextEdit")
        editor.document = "say dkssud"
        editor.selection = NSRange(location: 10, length: 0)
        corrector.request(client: editor, mode: .latin, isCurrent: { true })
        scheduler.advance(by: 0.1)
        #expect(editor.document == "say 안녕")
        #expect(editor.modes == [.hangul])
        #expect(events == [.corrected(undo: false)])
        corrector.request(client: editor, mode: .hangul, isCurrent: { true })
        scheduler.advance(by: 0.1)
        #expect(editor.document == "say dkssud")
        #expect(editor.modes == [.hangul, .latin])
        #expect(events == [.corrected(undo: false), .corrected(undo: true)])
    }

    @Test func aClientThatMovedOnBeforeTheReadIsLeftAlone() {
        let editor = Client(bundleID: "com.apple.TextEdit")
        editor.document = "dkssud"
        editor.selection = NSRange(location: 6, length: 0)
        corrector.request(client: editor, mode: .latin, isCurrent: { false })
        scheduler.advance(by: ShortcutCorrector.interval)
        #expect(editor.document == "dkssud")
        #expect(events == [.lostContext(byKeys: false)])
    }
}
