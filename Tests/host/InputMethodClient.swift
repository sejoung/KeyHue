import AppKit
import Carbon
import Darwin

// A real, separately launched Cocoa application. SwiftPM's test runner has no
// active app/window, so feeding keys to its NSTextView cannot verify IMK.
let parentID = "io.github.sejoung.keyhue.inputmethod.spike"
let hangulID = parentID + ".Hangul"
let latinID = parentID + ".Latin"

@MainActor
final class ProbeTextView: NSTextView {
    var rejectReplacement = false
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if rejectReplacement, replacementRange.location != NSNotFound { return }
        super.insertText(insertString, replacementRange: replacementRange)
    }
}

@MainActor
final class ClientDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: ProbeTextView!
    var report: [String] = [] {
        didSet { try? report.joined(separator: "\n").appending("\n").write(toFile: output, atomically: true, encoding: .utf8) }
    }
    var original: String?
    let output = CommandLine.arguments.dropFirst().first ?? ""
    let correctionProbe = CommandLine.arguments.contains("--correction-probe")

    func applicationDidFinishLaunching(_ notification: Notification) {
        original = current()
        window = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 440, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "KeyHue IMK test (temporary)"
        window.isReleasedWhenClosed = false
        view = ProbeTextView(frame: window.contentView!.bounds)
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do { try await runCases(); finish(success: true) }
            catch { report.append("FAIL: \(error)"); finish(success: false) }
        }
        // Avoid silently leaving a stuck GUI test alive.
        _ = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
            DispatchQueue.main.async { self.report.append("FAIL: timeout"); self.finish(success: false) }
        }
        // A stalled Swift continuation must not leave the temporary app alive.
        // The shell runner restores sources and the utility even on SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { _ = kill(getpid(), SIGTERM) }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ value: Bool, _ message: String) throws {
        if !value {
            let focus = message.hasPrefix("test lost focus")
                ? "; active=\(NSApp.isActive) key=\(window?.isKeyWindow ?? false) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")"
                : ""
            throw Failure(description: message + focus)
        }
    }
    func current() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? String
    }
    func select(_ id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return false }
        return TISSelectInputSource(source) == noErr
    }
    func selectAndWait(_ id: String) async throws {
        if view.inputContext?.selectedKeyboardInputSource == id { return }
        try require(select(id), "selection failed: \(id)")
        for _ in 0..<30 {
            if view.inputContext?.selectedKeyboardInputSource == id { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(description: "selected source mismatch: requested=\(id) context=\(view.inputContext?.selectedKeyboardInputSource ?? "nil") tis=\(current() ?? "nil")")
    }

    func send(_ code: UInt16, flags: CGEventFlags = [], delayMilliseconds: Int = 60) async throws {
        try require(NSApp.isActive && window.isKeyWindow, "test lost focus; refusing to inject keys")
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else {
            throw Failure(description: "invalid fixture key")
        }
        cg.flags = flags
        guard let event = NSEvent(cgEvent: cg) else { throw Failure(description: "invalid fixture event") }
        // NSTextView routes the event through its input context. Calling both
        // handleEvent and keyDown would deliver unhandled boundaries twice to IMK.
        view.keyDown(with: event)
        if delayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(delayMilliseconds)) }
    }

    func waitForInput(_ expected: String, mode: String, label: String) async throws {
        for _ in 0..<80 {
            try require(NSApp.isActive && window.isKeyWindow, "test lost focus while observing result")
            if view.string == expected, !view.hasMarkedText(), view.inputContext?.selectedKeyboardInputSource == mode { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(description: "\(label): receivedUnits=\(view.string.utf16.count) mode=\(view.inputContext?.selectedKeyboardInputSource ?? "nil")")
    }
    func runCases() async throws {
        for _ in 0..<50 {
            if NSApp.isActive && window.isKeyWindow { break }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(NSApp.isActive && window.isKeyWindow, "test application must be active with a key window: active=\(NSApp.isActive) key=\(window.isKeyWindow) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        let codes: [Character: UInt16] = ["a":0,"b":11,"c":8,"d":2,"e":14,"f":3,"g":5,"h":4,"i":34,"k":40,"l":37,"m":46,"n":45,"o":31,"q":12,
                                          "r":15,"s":1,"t":17,"u":32,"w":13,"x":7," ":49,"\u{8}":51]
        let cases: [(String, String, String)] = [
            ("com.apple.keylayout.ABC", "abc ", "abc "),
            ("com.apple.inputmethod.Korean.2SetKorean", "rk ", "가 "),
            (hangulID, "dkssud ", "안녕 "),
            (latinID, "hello world ", "hello world "),
            (hangulID, "rkrk ", "가가 "),
            (latinID, "abc\u{8}d ", "abd "),
            (hangulID, "rhkrt\u{8} ", "곽 "),
            (hangulID, "rhkrtk ", "곽사 "),
            (latinID, "hello world again ", "hello world again ")
        ]
        for (id, keys, expected) in cases {
            try require(NSApp.isActive && window.isKeyWindow, "test lost focus; refusing to inject keys")
            view.inputContext?.discardMarkedText()
            view.string = ""
            try await selectAndWait(id)
            for key in keys {
                try require(NSApp.isActive && window.isKeyWindow, "test lost focus during case")
                guard let code = codes[key], let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                      let event = NSEvent(cgEvent: cg) else {
                    throw Failure(description: "invalid fixture key")
                }
                // Sends only to this application's test window, never the OS.
                view.keyDown(with: event)
                try await Task.sleep(for: .milliseconds(60))
                if id == hangulID || id == latinID {
                    try require(view.markedRange().location == NSNotFound || view.markedRange().length <= 1, "marked range exceeds one character: \(id)")
                    if key.isLetter {
                        try require(view.hasMarkedText() && view.markedRange().length == 1,
                                    "selected IME did not mark the typed letter: \(id)")
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(200))
            try require(view.string == expected, "client text mismatch for \(id): expectedCount=\(expected.count) receivedCount=\(view.string.count)")
            try require(!view.hasMarkedText(), "composition not committed at boundary: \(id)")
            report.append("PASS: \(id) composition, marked range and boundary")
        }
        try await runCommitFirstCases(codes: codes)
        try await runModeRoundTrips(codes: codes)
        if correctionProbe { try await runCorrectionCases(codes: codes) }
    }

    /// 조합 중에 커서 키·Return·Tab·단축키·클릭이 와도 마지막 글자가 남아야 한다(먼저 확정한 뒤 앱이 처리).
    func runCommitFirstCases(codes: [Character: UInt16]) async throws {
        enum Interrupt { case key(UInt16, CGEventFlags), click }
        let cases: [(String, Interrupt, String)] = [
            ("left arrow", .key(123, []), "안"),
            ("right arrow", .key(124, []), "안"),
            ("return", .key(36, []), "안\n"),
            ("tab", .key(48, []), "안\t"),
            ("command right arrow", .key(124, .maskCommand), "안"),
            ("mouse down", .click, "안")
        ]
        for (name, interrupt, expected) in cases {
            try require(NSApp.isActive && window.isKeyWindow, "test lost focus; refusing to inject keys")
            view.inputContext?.discardMarkedText()
            view.string = ""
            try await selectAndWait(hangulID)
            for key in "dks" {
                guard let code = codes[key], let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                      let event = NSEvent(cgEvent: cg) else { throw Failure(description: "invalid fixture key") }
                view.keyDown(with: event)
                try await Task.sleep(for: .milliseconds(60))
            }
            try require(view.hasMarkedText(), "composition expected before \(name)")
            switch interrupt {
            case .key(let code, let flags):
                guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { throw Failure(description: "invalid key") }
                cg.flags = flags
                guard let event = NSEvent(cgEvent: cg) else { throw Failure(description: "invalid key") }
                view.keyDown(with: event)
            case .click:
                // Only the input context sees the click; the view's tracking loop is not entered.
                guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failure(description: "invalid click") }
                _ = view.inputContext?.handleEvent(event)
            }
            try await Task.sleep(for: .milliseconds(200))
            try require(view.string == expected, "last syllable lost on \(name): expectedCount=\(expected.count) receivedCount=\(view.string.count)")
            try require(!view.hasMarkedText(), "composition left marked after \(name)")
            report.append("PASS: last syllable kept on \(name)")
        }
    }

    func runModeRoundTrips(codes: [Character: UInt16]) async throws {
        view.inputContext?.discardMarkedText()
        view.string = ""
        for _ in 0..<3 {
            for (id, keys) in [(hangulID, "rk "), (latinID, "abc "), (hangulID, "sk ")] {
                try await selectAndWait(id)
                // No extra settling delay after confirmation: inspect the first key.
                for key in keys { try await send(codes[key]!) }
            }
        }
        try require(view.string == String(repeating: "가 abc 나 ", count: 3), "first key or mode round-trip mismatch")
        report.append("PASS: repeated Korean/English round trips and first key")
    }

    func runCorrectionCases(codes: [Character: UInt16]) async throws {
        // Observe the view directly; no synthetic observation keys are sent.
        // A word undone once is not corrected again (ADR 0065): every undo uses its own word.
        for (prefix, word, hangul) in [("", "rkatk", "감사"), ("😀 ", "gksrmf", "한글"),
                                       ("e\u{301} ", "dhsmf", "오늘"), ("👨‍👩‍👧‍👦 ", "tkfkd", "사랑")] {
            view.inputContext?.discardMarkedText()
            view.string = prefix
            view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            try await selectAndWait(latinID)
            for key in word {
                try await send(codes[key]!)
                try require(view.hasMarkedText() && view.markedRange().length == 1, "probe letter did not reach the Latin IME")
            }
            try await send(49)
            try await waitForInput(prefix + hangul + " ", mode: hangulID, label: "automatic correction")
            try require(!view.hasMarkedText() && view.inputContext?.selectedKeyboardInputSource == hangulID, "correction mode not confirmed")
            try await send(51)
            try await waitForInput(prefix + word, mode: latinID, label: "automatic undo")
            try require(view.string == prefix + word, "undo must restore original without deleting another character")
            try require(view.inputContext?.selectedKeyboardInputSource == latinID, "undo mode not confirmed")
            try await send(49)
            try await Task.sleep(for: .milliseconds(350))
            try require(view.string == prefix + word + " ", "rejected correction repeated or boundary duplicated")
            try await send(51)
            try require(view.string == prefix + word, "normal Backspace after rejection mismatch")
            report.append("PASS: correction, immediate undo, rejected Space and UTF-16 prefixUnits=\(prefix.utf16.count)")
        }
        // The undone word stays uncorrected in a new document of the same client.
        view.inputContext?.discardMarkedText()
        view.string = ""
        try await selectAndWait(latinID)
        for key in "rkatk " { try await send(codes[key]!) }
        try await Task.sleep(for: .milliseconds(350))
        try require(view.string == "rkatk " && view.inputContext?.selectedKeyboardInputSource == latinID,
                    "an undone word was corrected again")
        report.append("PASS: an undone word is not corrected again")
        // Navigation invalidates the undo snapshot even if the cursor returns.
        view.inputContext?.discardMarkedText()
        view.string = ""
        try await selectAndWait(latinID)
        for key in "dkssud " { try await send(codes[key]!) }
        try await waitForInput("안녕 ", mode: hangulID, label: "correction before navigation")
        try await send(123)
        try await send(124)
        try await send(51)
        try require(view.string == "안녕", "navigation must invalidate correction undo")
        report.append("PASS: navigation invalidates immediate undo")
        for keys in ["hello ", "xdkssud "] {
            view.inputContext?.discardMarkedText()
            view.string = ""
            try await selectAndWait(latinID)
            for key in keys { try await send(codes[key]!) }
            try require(view.string == keys, "non-fixture word was changed")
        }
        report.append("PASS: normal English and identifier suffix unchanged")
        try await runAutomaticRaces(codes: codes)
        try await runContextChanges(codes: codes)
    }

    func resetRaceFixture() async throws {
        if view.hasMarkedText() { try await send(49) }
        // Finish through the native boundary before replacing
        // the fixture document; zero-delay events within a burst stay intact.
        try await Task.sleep(for: .milliseconds(30))
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try await selectAndWait(latinID)
        try await Task.sleep(for: .milliseconds(30))
    }
    func runAutomaticRaces(codes: [Character: UInt16]) async throws {
        // Do not yield between Space and the next key. The scheduler may finish
        // first or cancel; both must preserve the key and match the visible mode.
        for _ in 0..<3 {
            report.append("PROBE: burst begins")
            try await resetRaceFixture()
            for key in "dkssud " { try await send(codes[key]!, delayMilliseconds: 0) }
            try await send(15, delayMilliseconds: 0) // r / ㄱ
            try await Task.sleep(for: .milliseconds(350))
            let latin = view.inputContext?.selectedKeyboardInputSource == latinID
            try require(view.string == (latin ? "dkssud r" : "안녕 ㄱ"), "fast key was lost, duplicated or mapped to the wrong mode")
            try await send(40) // k / ㅏ, continues the existing composition
            try require(view.string == (latin ? "dkssud rk" : "안녕 가"), "composition after fast key mismatch")
        }
        report.append("PASS: zero-delay next key preserved in three bursts")

        try await resetRaceFixture()
        // Its own word: a Backspace that lands after the correction is an undo (ADR 0065).
        for key in "dlqfur " { try await send(codes[key]!, delayMilliseconds: 0) }
        try await send(51, delayMilliseconds: 0)
        try await waitForInput("dlqfur", mode: latinID, label: "fast Backspace after Space")
        report.append("PASS: zero-delay Backspace preserves original without extra deletion")

        try await resetRaceFixture()
        for key in "dlqfurrl " { try await send(codes[key]!) }
        try await waitForInput("입력기 ", mode: hangulID, label: "correction before fast undo")
        try await send(51, delayMilliseconds: 0)
        try await send(15, delayMilliseconds: 0)
        try await Task.sleep(for: .milliseconds(350))
        let undoLatin = view.inputContext?.selectedKeyboardInputSource == latinID
        try require(view.string == (undoLatin ? "dlqfurrlr" : "입력기 ㄱ"), "fast key during undo was lost or mapped to wrong mode")
        report.append("PASS: zero-delay key during undo preserves confirmed mode and input")

        try await resetRaceFixture()
        for key in "dkssud " { try await send(codes[key]!, delayMilliseconds: 0) }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(350))
        try require(view.string == "dkssud " && view.selectedRange().location == 0, "automatic work overwrote a moved cursor")
        report.append("PASS: cursor movement cancels automatic replacement")

        try await resetRaceFixture()
        for key in "dkssud " { try await send(codes[key]!, delayMilliseconds: 0) }
        view.string = "외부 편집"
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        try await Task.sleep(for: .milliseconds(350))
        try require(view.string == "외부 편집", "automatic work overwrote external editing")
        report.append("PASS: external editing cancels automatic replacement")

        try await resetRaceFixture()
        view.rejectReplacement = true
        for key in "dkssud " { try await send(codes[key]!) }
        try await Task.sleep(for: .milliseconds(350))
        try require(view.string == "dkssud " && view.inputContext?.selectedKeyboardInputSource == latinID, "rejected edit did not preserve original and one Space")
        view.rejectReplacement = false
        try await send(0)
        try require(view.string == "dkssud a", "typing after rejected edit was blocked")
        report.append("PASS: rejected replacement times out and typing continues")
    }

    func runContextChanges(codes: [Character: UInt16]) async throws {
        let primary = view!
        let secondary = ProbeTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 100))
        primary.addSubview(secondary)
        defer {
            window.makeFirstResponder(primary)
            view = primary
            secondary.removeFromSuperview()
        }

        // Change the real input context before the first automatic observation.
        try await resetRaceFixture()
        for key in "dkssud " { try await send(codes[key]!, delayMilliseconds: 0) }
        try require(window.makeFirstResponder(secondary), "cannot focus second field")
        view = secondary
        try await Task.sleep(for: .milliseconds(350))
        try require(primary.string == "dkssud " && secondary.string.isEmpty,
                    "pending correction edited an inactive or different field")
        try await selectAndWait(latinID)
        try await send(0)
        try await send(49)
        try require(secondary.string == "a ", "first key after field switch mismatch")
        report.append("PASS: field switch cancels pending correction and preserves first key")

        try require(window.makeFirstResponder(primary), "cannot return to first field")
        view = primary
        try await resetRaceFixture()
        for key in "dkssud " { try await send(codes[key]!) }
        try await waitForInput("안녕 ", mode: hangulID, label: "correction before field switch")
        try require(window.makeFirstResponder(secondary), "cannot leave corrected field")
        view = secondary
        try await Task.sleep(for: .milliseconds(30))
        try require(window.makeFirstResponder(primary), "cannot refocus corrected field")
        view = primary
        // Let Cocoa publish the context activation before directly calling
        // keyDown; a real event arrives on a later run-loop turn as well.
        try await Task.sleep(for: .milliseconds(30))
        try await send(51)
        try require(primary.string == "안녕", "field round trip kept stale correction undo")
        report.append("PASS: field round trip invalidates immediate undo")

        try await resetRaceFixture()
        for key in "dkssud " { try await send(codes[key]!, delayMilliseconds: 0) }
        try await selectAndWait("com.apple.keylayout.ABC")
        try await Task.sleep(for: .milliseconds(350))
        try require(primary.string == "dkssud " && view.inputContext?.selectedKeyboardInputSource == "com.apple.keylayout.ABC",
                    "pending correction overrode external input source selection")
        try await send(15)
        try require(primary.string == "dkssud r", "first ABC key after cancellation mismatch")
        report.append("PASS: external ABC selection cancels pending correction")

        try await resetRaceFixture()
        for key in "dkssud " { try await send(codes[key]!, delayMilliseconds: 0) }
        try await selectAndWait(hangulID)
        try await Task.sleep(for: .milliseconds(350))
        try require(primary.string == "dkssud " && view.inputContext?.selectedKeyboardInputSource == hangulID,
                    "pending correction ignored external owned mode selection")
        try await send(15)
        try await send(40)
        try await send(49)
        try require(primary.string == "dkssud 가 ", "first Hangul composition after cancellation mismatch")
        report.append("PASS: external Hangul selection cancels pending correction")
    }
    func finish(success: Bool) -> Never {
        view?.inputContext?.discardMarkedText()
        if let original { _ = select(original) }
        report.append(success ? "PASS: actual IMK client acceptance" : "FAIL: actual IMK client acceptance")
        try? report.joined(separator: "\n").appending("\n").write(toFile: output, atomically: true, encoding: .utf8)
        exit(success ? 0 : 1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ClientDelegate()
app.delegate = delegate
app.run()
