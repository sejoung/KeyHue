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
if args == ["--correction-settings-changed"] {
    // The runner changed the input method's test override (ADR 0064); ask it to re-read.
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("io.github.sejoung.keyhue.inputmethod.correction-settings-changed"),
        object: nil, userInfo: nil, deliverImmediately: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    exit(0)
}
guard args.count == 4, let pid = Int32(args[0]), pid > 0,
      args[3].hasPrefix("KeyHueIMK-") else { fail("invalid fixture request") }
guard AXIsProcessTrusted() else { fail("native event runner needs existing Accessibility permission") }
guard CGPreflightPostEventAccess() else { fail("native event runner needs existing event-posting permission") }
guard let front = NSWorkspace.shared.frontmostApplication,
      front.processIdentifier == pid, front.bundleIdentifier == "com.apple.TextEdit" else {
    fail("native key: test lost TextEdit focus front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2)
var windowValue: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
      let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { fail("native key: TextEdit has no focused window") }
let window = windowValue as! AXUIElement
var titleValue: CFTypeRef?
guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
      let title = titleValue as? String, title.contains(args[3]) else {
    // Only generated fixture titles are reported; a user's window only by length.
    let shown = (titleValue as? String).map { $0.hasPrefix("KeyHueIMK-") ? $0 : "other(titleLength=\($0.count))" } ?? "none"
    fail("native key: focused window is not the fixture focused=\(shown)")
}
if args[1] == "--request-source" {
    let request = args[2].split(separator: ":")
    guard request.count == 2,
          ["com.apple.keylayout.ABC", "io.github.sejoung.keyhue.inputmethod.spike.Hangul", "io.github.sejoung.keyhue.inputmethod.spike.Latin"].contains(String(request[0])),
          let ordinal = Int(request[1]), ordinal > 0, ordinal <= 100 else { fail("invalid live source request") }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("io.github.sejoung.keyhue.test-source-request." + args[3]),
        object: String(request[0]), userInfo: ["request": ordinal], deliverImmediately: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    exit(0)
}
if args[1] == "--service-state" {
    // Diagnostic only: whether a service process exists when the first key is sent.
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.sejoung.keyhue.inputmethod.spike")
    let pids = running.map { String($0.processIdentifier) }.joined(separator: ",")
    print("PROBE: service before first key running=\(!running.isEmpty) PIDs=\(pids.isEmpty ? "none" : pids)")
    exit(0)
}
if args[1] == "--stop-service" || args[1] == "--stop-service-if-running" {
    let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/KeyHueInputMethodSpike.app").standardizedFileURL
    guard URL(fileURLWithPath: args[2]).standardizedFileURL == expected,
          let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
          Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String == "com.apple.keylayout.ABC" else { fail("cold start requires ABC in the fixture") }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.sejoung.keyhue.inputmethod.spike")
    if running.isEmpty, args[1] == "--stop-service-if-running" {
        print("PROBE: cold start found no running service")
        exit(0)
    }
    guard !running.isEmpty, running.allSatisfy({ $0.bundleURL?.standardizedFileURL == expected }) else { fail("cannot identify the installed service for cold start") }
    for service in running {
        guard service.terminate() else { fail("installed service refused termination") }
    }
    let deadline = Date().addingTimeInterval(2)
    while running.contains(where: { !$0.isTerminated }), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard running.allSatisfy(\.isTerminated),
          NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.sejoung.keyhue.inputmethod.spike").isEmpty else { fail("installed service did not stop") }
    print("PROBE: cold start stopped service PIDs=" + running.map { String($0.processIdentifier) }.joined(separator: ","))
    exit(0)
}
let usesShortcut = args[1] == "--input-source-shortcut"
let code: UInt16
let flags: UInt64
if usesShortcut {
    guard args[2] == "60",
          let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any],
          let shortcut = hotKeys["60"] as? [String: Any], shortcut["enabled"] as? Bool == true,
          let value = shortcut["value"] as? [String: Any], value["type"] as? String == "standard",
          let parameters = value["parameters"] as? [NSNumber], parameters.count == 3,
          parameters[1].intValue >= 0, parameters[1].intValue < 128 else { fail("configured previous-input-source shortcut unavailable") }
    code = parameters[1].uint16Value
    flags = parameters[2].uint64Value
    let allowed = CGEventFlags([.maskCommand, .maskControl, .maskAlternate, .maskShift]).rawValue
    guard flags != 0, flags & ~allowed == 0 else { fail("unsupported input-source shortcut modifiers") }
    print("PROBE: configured input-source shortcut keyCode=\(code) flags=\(flags)")
} else {
    guard let keyCode = UInt16(args[1]), keyCode < 128, let eventFlags = UInt64(args[2]),
          // ⌘ for select-all, ⌥ for the correction shortcut (ADR 0068).
          [0, CGEventFlags.maskCommand.rawValue, CGEventFlags.maskAlternate.rawValue].contains(eventFlags) else { fail("invalid fixture event") }
    code = keyCode
    flags = eventFlags
}
if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
   let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
    let id = Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    print("PROBE: event source=" + id)
}
guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { fail("cannot create fixture key") }
down.flags = CGEventFlags(rawValue: flags)
up.flags = CGEventFlags(rawValue: flags)
var modifierDown: [CGEvent] = []
var modifierUp: [CGEvent] = []
if usesShortcut {
    let modifiers: [(CGEventFlags, UInt16)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55)]
    var held = CGEventFlags()
    for (flag, keyCode) in modifiers where flags & flag.rawValue != 0 {
        guard let press = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let release = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { fail("cannot create fixture shortcut modifier") }
        release.flags = held
        held.insert(flag)
        press.flags = held
        modifierDown.append(press)
        modifierUp.insert(release, at: 0)
    }
}
// Global shortcuts also need modifier key transitions. Prepare every event
// before pressing any modifier, and always send its matching release.
for event in modifierDown { event.post(tap: .cghidEventTap) }
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
for event in modifierUp { event.post(tap: .cghidEventTap) }
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
