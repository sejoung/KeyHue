import AppKit
import Carbon

// Hardware-path keys for the Ghostty test window (ADR 0066), only while the
// runner's own Ghostty process is frontmost.
//   GhosttyKeys <pid> <key code>[@<CGEventFlags raw value>]...
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
    let flags = parts.count == 2 ? UInt64(parts[1]) : 0
    guard let flags else { fail("invalid key flags") }
    guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == pid,
          front.bundleIdentifier == "com.mitchellh.ghostty" else { fail("test lost the Ghostty test window") }
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("cannot create key event") }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    usleep(120_000)
}
