import AppKit
import ApplicationServices

// Explicit local UI acceptance check. Only reads the Keyboard input-source
// sheet; it never adds/removes sources or presses a macOS consent button.
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 20 else { return [] }
    let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return [element] + children.flatMap { descendants($0, depth: depth + 1) }
}
func description(_ element: AXUIElement) -> String { attribute(element, kAXDescriptionAttribute) as? String ?? "" }
func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) as? String ?? "" }
func fail(_ message: String) -> Never { fputs("FAIL: \(message)\n", stderr); exit(1) }

guard AXIsProcessTrusted() else { fail("This opt-in UI test needs Accessibility permission for its runner; it never requests or resets it.") }
guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { fail("settings URL") }
guard NSWorkspace.shared.open(url) else { fail("cannot open Keyboard settings") }
RunLoop.current.run(until: Date().addingTimeInterval(1))
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { fail("System Settings is not running") }
let root = AXUIElementCreateApplication(app.processIdentifier)
guard let window = (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.first else { fail("no settings window") }
var tree = descendants(window)
if !tree.contains(where: { role($0) == "AXSheet" }) {
    let editNames = ["Edit…", "Edit...", "편집…", "編集…"]
    guard let edit = tree.first(where: { role($0) == "AXButton" && editNames.contains(description($0)) }) else { fail("Keyboard Text Input Edit button not found") }
    guard AXUIElementPerformAction(edit, kAXPressAction as CFString) == .success else { fail("cannot open input source sheet") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    tree = descendants(window)
}
guard let sheet = tree.first(where: { role($0) == "AXSheet" }) else { fail("input source sheet not found") }
let ownedLabels = descendants(sheet).filter { role($0) == "AXUnknown" }.map(description).filter { $0.hasPrefix("KeyHue") }
for label in ownedLabels { print("registered: \(label)") }
guard ownedLabels.count == 2 else { fail("expected exactly two KeyHue modes in the actual input-source list; found \(ownedLabels.count)") }
guard ownedLabels.contains(where: { $0.contains("두벌식") || $0.contains("Korean") }),
      ownedLabels.contains(where: { $0.contains("영문") || $0.contains("English") }) else { fail("both Korean and English modes must be visible") }
print("PASS: actual System Settings lists both KeyHue modes (pid \(app.processIdentifier))")
