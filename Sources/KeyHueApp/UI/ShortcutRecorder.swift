import AppKit
import KeyHueCore
import SwiftUI

/// Records the correction shortcut (ADR 0068): click, then press the keys. Esc
/// cancels. Keys the input method cannot own are refused with a hint.
struct ShortcutRecorder: View {
    @Binding var shortcut: CorrectionShortcut
    @State private var recording = false
    @State private var refused = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack {
                Button(recording ? L("Press a Shortcut…") : shortcut.displayName) {
                    recording ? stop() : start()
                }
                .monospacedDigit()
                if shortcut != .default {
                    Button(L("Restore Defaults")) { shortcut = .default }
                }
            }
            if refused {
                Text(L("Use ⌥ or ⌃ with a key, or ⇧ with Space or Return."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        refused = false
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
                return nil
            }
            let recorded = CorrectionShortcut(keyCode: event.keyCode, modifiers: Self.modifiers(event.modifierFlags))
            if recorded.isAllowed {
                shortcut = recorded
                stop()
            } else {
                refused = true
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> CorrectionShortcut.Modifiers {
        var modifiers: CorrectionShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}
