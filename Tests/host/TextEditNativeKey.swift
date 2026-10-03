import AppKit
import ApplicationServices
import Carbon

// One hardware-path key pair, only while the checked TextEdit fixture is focused.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let args = Array(CommandLine.arguments.dropFirst())
if args.count == 2, args[0] == "--source-name" {
    let filter = [kTISPropertyInputSourceID as String: args[1]] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let source = sources.first,
          let value = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { fail("input source name unavailable") }
    print(Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String)
    exit(0)
}
guard args.count == 4, let pid = Int32(args[0]), pid > 0,
      let code = UInt16(args[1]), code < 128, let flags = UInt64(args[2]),
      flags == 0 || flags == CGEventFlags.maskCommand.rawValue,
      args[3].hasPrefix("KeyHueIMK-") else { fail("invalid fixture event") }
guard AXIsProcessTrusted() else { fail("native event runner needs existing Accessibility permission") }
guard CGPreflightPostEventAccess() else { fail("native event runner needs existing event-posting permission") }
guard let front = NSWorkspace.shared.frontmostApplication,
      front.processIdentifier == pid, front.bundleIdentifier == "com.apple.TextEdit" else { fail("test lost TextEdit focus") }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2)
var windowValue: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
      let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { fail("test lost focused fixture window") }
let window = windowValue as! AXUIElement
var titleValue: CFTypeRef?
guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
      let title = titleValue as? String, title.contains(args[3]) else { fail("test lost fixture window title") }
if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
   let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
    let id = Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    print("PROBE: event source=" + id)
}
guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { fail("cannot create fixture key") }
down.flags = CGEventFlags(rawValue: flags)
up.flags = CGEventFlags(rawValue: flags)
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
