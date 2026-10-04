import AppKit
import Carbon

// ADR 0064 step 1 helper, run by the shell runner (which holds the event-posting
// permission), never by the test client. It only switches input sources while
// the dedicated manual-probe test client is frontmost.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let clientID = "io.github.sejoung.keyhue.testclient.manual-probe"
let args = Array(CommandLine.arguments.dropFirst())

if args.count == 2, args[0] == "--source-name" {
    let filter = [kTISPropertyInputSourceID as String: args[1]] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let source = sources.first,
          let value = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { fail("input source name unavailable") }
    print(Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String)
    exit(0)
}
guard args == ["--shortcut"] else { fail("usage: --shortcut | --source-name <id>") }
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == clientID else { fail("manual probe client is not frontmost") }
guard CGPreflightPostEventAccess() else { fail("runner needs existing event-posting permission") }
// The user's configured "Select the previous input source" (system hot key 60).
guard let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any],
      let shortcut = hotKeys["60"] as? [String: Any], shortcut["enabled"] as? Bool == true,
      let value = shortcut["value"] as? [String: Any], value["type"] as? String == "standard",
      let parameters = value["parameters"] as? [NSNumber], parameters.count == 3,
      parameters[1].intValue >= 0, parameters[1].intValue < 128 else { fail("configured previous-input-source shortcut unavailable") }
let code = parameters[1].uint16Value
let flags = parameters[2].uint64Value
let allowed = CGEventFlags([.maskCommand, .maskControl, .maskAlternate, .maskShift]).rawValue
guard flags != 0, flags & ~allowed == 0 else { fail("unsupported input-source shortcut modifiers") }
guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { fail("cannot create shortcut key") }
down.flags = CGEventFlags(rawValue: flags)
up.flags = CGEventFlags(rawValue: flags)
var modifierDown: [CGEvent] = []
var modifierUp: [CGEvent] = []
var held = CGEventFlags()
for (flag, keyCode) in [(CGEventFlags.maskControl, UInt16(59)), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55)]
where flags & flag.rawValue != 0 {
    guard let press = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let release = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { fail("cannot create modifier") }
    release.flags = held
    held.insert(flag)
    press.flags = held
    modifierDown.append(press)
    modifierUp.insert(release, at: 0)
}
for event in modifierDown { event.post(tap: .cghidEventTap) }
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
for event in modifierUp { event.post(tap: .cghidEventTap) }
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
