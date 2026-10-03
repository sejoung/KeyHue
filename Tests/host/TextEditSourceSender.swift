import AppKit
import Carbon

// A non-activating, live AppKit source requester. Selection completion is
// deliberately separate from the TextEdit first-key acceptance result.
@MainActor
final class SourceSender: NSObject, NSApplicationDelegate {
    private var directory: URL!
    private var editorPID: Int32 = 0
    private var lastRequest = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let pid = Int32(args[1]),
              args[2].hasPrefix("KeyHueIMK-"),
              URL(fileURLWithPath: args[0]).deletingLastPathComponent().lastPathComponent == "input-method-textedit",
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else { exit(64) }
        editorPID = pid
        directory = URL(fileURLWithPath: args[0], isDirectory: true)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(selectSource(_:)),
            name: Notification.Name("io.github.sejoung.keyhue.test-source-request." + args[2]),
            object: nil, suspensionBehavior: .deliverImmediately)
        writeReport(request: 0, target: "ready", status: OSStatus(noErr))
        // One process handles every request; application launch cannot refresh
        // the editor's context between the tested source round trips.
        Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in exit(0) }
    }

    @objc private func selectSource(_ notification: Notification) {
        guard Thread.isMainThread, let id = notification.object as? String,
              ["com.apple.keylayout.ABC", "io.github.sejoung.keyhue.inputmethod.spike.Hangul", "io.github.sejoung.keyhue.inputmethod.spike.Latin"].contains(id),
              let request = notification.userInfo?["request"] as? Int,
              request == lastRequest + 1,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == editorPID,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else { return }
        lastRequest = request
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { writeReport(request: request, target: id, status: OSStatus(paramErr)); return }
        let status = TISSelectInputSource(source)
        writeReport(request: request, target: id, status: status)
    }

    private func writeReport(request: Int, target: String, status: OSStatus) {
        let report = "PROBE: live AppKit sender pid=\(ProcessInfo.processInfo.processIdentifier) request=\(request) target=\(target) status=\(status)\n"
        do { try report.write(to: directory.appendingPathComponent("source-sender-\(request).log"), atomically: true, encoding: .utf8) } catch { exit(1) }
    }
}

let app = NSApplication.shared
let delegate = SourceSender()
app.setActivationPolicy(.prohibited)
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
