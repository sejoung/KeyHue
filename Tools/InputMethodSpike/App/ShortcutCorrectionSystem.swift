import AppKit
import InputMethodKit
import KeyHueInputMethodSpikeCore

/// Main-queue work items on the system uptime clock, the pattern every
/// correction step here uses.
final class MainQueueScheduler: CorrectionScheduling {
    var now: Double { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem {
            guard Thread.isMainThread else { return }
            work()
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        } else {
            DispatchQueue.main.async(execute: item)
        }
    }
}

/// The front app, held modifiers and KeyHue's key posting (ADR 0073).
final class SystemTerminalKeys: TerminalKeyPosting {
    /// IMK calls this server on the main thread.
    func frontApp() -> (bundleID: String?, pid: pid_t)? {
        guard let front = MainActor.assumeIsolated({ NSWorkspace.shared.frontmostApplication }) else { return nil }
        return (front.bundleIdentifier, front.processIdentifier)
    }

    var modifiersHeld: Bool {
        !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty
    }

    /// Waits up to `TerminalKeyPost.replyTimeout` for KeyHue off the main thread:
    /// this one input method process serves every app, whose typing must go on.
    func requestBackspaces(_ count: Int, to pid: pid_t, completion: @escaping (TerminalKeyDelivery) -> Void) {
        let resume = MainThreadOnly(completion)
        DispatchQueue.global(qos: .userInitiated).async {
            let delivery = TerminalKeyPostClient.backspaces(count, to: pid)
            DispatchQueue.main.async { resume.value(delivery) }
        }
    }
}

/// An IMK client as `ShortcutCorrector` sees it.
final class IMKShortcutClient: ShortcutCorrectionClient {
    private let client: any IMKTextInput

    init(_ client: any IMKTextInput) { self.client = client }

    var bundleID: String? { client.bundleIdentifier() }
    var selection: NSRange { client.selectedRange() }
    var hasMarkedText: Bool {
        let marked = client.markedRange()
        return marked.location != NSNotFound && marked.length > 0
    }
    func text(in range: NSRange) -> String? { client.attributedSubstring(from: range)?.string }
    func replace(_ range: NSRange, with text: String) { client.insertText(text, replacementRange: range) }
    func insert(_ text: String) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }
    func select(_ mode: ProbeSession.Mode) { client.selectMode(mode.inputSourceID) }
}

/// State of this main-thread adapter, carried through a background request and
/// used again only on the main thread.
private struct MainThreadOnly<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
