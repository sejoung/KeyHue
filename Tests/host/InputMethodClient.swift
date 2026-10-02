import AppKit
import Carbon

// A real, separately launched Cocoa application. SwiftPM's test runner has no
// active app/window, so feeding keys to its NSTextView cannot verify IMK.
let parentID = "io.github.sejoung.keyhue.inputmethod.spike"
let hangulID = parentID + ".Hangul"
let latinID = parentID + ".Latin"

@MainActor
final class ClientDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: NSTextView!
    var report: [String] = []
    var original: String?
    let output = CommandLine.arguments.dropFirst().first ?? ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        original = current()
        window = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 440, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "KeyHue IMK test (temporary)"
        window.isReleasedWhenClosed = false
        view = NSTextView(frame: window.contentView!.bounds)
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
        _ = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
            MainActor.assumeIsolated { self.report.append("FAIL: timeout"); self.finish(success: false) }
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
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
    func runCases() async throws {
        for _ in 0..<30 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(NSApp.isActive && window.isKeyWindow, "test application must be active with a key window")
        let codes: [Character: UInt16] = ["a":0,"b":11,"c":8,"d":2,"e":14,"g":5,"h":4,"i":34,"k":40,"l":37,"n":45,"o":31,"r":15,"s":1,"t":17,"u":32,"w":13," ":49,"\u{8}":51]
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
            try require(select(id), "selection failed: \(id)")
            try await Task.sleep(for: .milliseconds(250))
            try require(current() == id && view.inputContext?.selectedKeyboardInputSource == id, "selected source mismatch: \(id)")
            for key in keys {
                try require(NSApp.isActive && window.isKeyWindow, "test lost focus during case")
                guard let code = codes[key], let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                      let event = NSEvent(cgEvent: cg) else {
                    throw Failure(description: "invalid fixture key")
                }
                // Sends only to this application's test window, never the OS.
                if view.inputContext?.handleEvent(event) != true { view.keyDown(with: event) }
                try await Task.sleep(for: .milliseconds(60))
                if id == hangulID || id == latinID {
                    try require(view.markedRange().location == NSNotFound || view.markedRange().length <= 1, "marked range exceeds one character: \(id)")
                }
            }
            try await Task.sleep(for: .milliseconds(200))
            try require(view.string == expected, "client text mismatch for \(id): expectedCount=\(expected.count) receivedCount=\(view.string.count)")
            try require(!view.hasMarkedText(), "composition not committed at boundary: \(id)")
            report.append("PASS: \(id) composition, marked range and boundary")
        }
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
