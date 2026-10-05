import AppKit
import Carbon

// Hardware-path keys for the Ghostty test window (ADR 0066), only while the
// runner's own Ghostty process is frontmost.
//   GhosttyKeys <pid> <key code>[@<CGEventFlags raw value>[x<presses while the modifiers are held>]]...
//   GhosttyKeys --source-name <input source ID>
//   GhosttyKeys --correction-settings-changed   (the input method rereads its test override)
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let args = Array(CommandLine.arguments.dropFirst())
if args == ["--correction-settings-changed"] {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("io.github.sejoung.keyhue.inputmethod.correction-settings-changed"), object: nil,
        userInfo: nil, deliverImmediately: true)
    exit(0)
}
if args.count == 2, args[0] == "--source-name" {
    let filter = [kTISPropertyInputSourceID as String: args[1]] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let source = sources.first,
          let value = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { fail("input source name unavailable") }
    print(Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String)
    exit(0)
}
guard args.count >= 2, let pid = Int32(args[0]), pid > 0 else { fail("usage: GhosttyKeys <pid> <key code>...") }
guard CGPreflightPostEventAccess() else { fail("key sender needs existing event-posting permission") }
for argument in args.dropFirst() {
    let parts = argument.split(separator: "@").map(String.init)
    guard let code = CGKeyCode(parts[0]), parts.count <= 2 else { fail("invalid key code") }
    let modifierParts = parts.count == 2 ? parts[1].split(separator: "x").map(String.init) : ["0"]
    guard let flags = UInt64(modifierParts[0]), modifierParts.count <= 2,
          let presses = modifierParts.count == 2 ? Int(modifierParts[1]) : 1, (1...5).contains(presses) else { fail("invalid key flags") }
    guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == pid,
          front.bundleIdentifier == "com.mitchellh.ghostty" else { fail("test lost the Ghostty test window") }
    // Modifiers are pressed and released as on a keyboard: the input method
    // waits for the shortcut's modifiers to be released (ADR 0068).
    let modifiers: [(CGEventFlags, CGKeyCode)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55)]
        .filter { CGEventFlags(rawValue: flags).contains($0.0) }
    func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("cannot create key event") }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    var held: CGEventFlags = []
    for (flag, modifier) in modifiers { held.insert(flag); post(modifier, down: true, flags: held) }
    for press in 0..<presses {
        if press > 0 { usleep(150_000) }
        for down in [true, false] { post(code, down: down, flags: CGEventFlags(rawValue: flags)) }
    }
    for (flag, modifier) in modifiers.reversed() { held.remove(flag); post(modifier, down: false, flags: held) }
    usleep(120_000)
}
