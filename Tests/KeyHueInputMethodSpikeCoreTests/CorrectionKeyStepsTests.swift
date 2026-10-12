import KeyHueCore
import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0064, 0068: which correction steps a key goes through once the session has its mode.
@Suite("Correction key steps")
struct CorrectionKeyStepsTests {
    /// An unrouted client never enters the correction path, whatever the key.
    @Test(arguments: [false, true])
    func anUnroutedClientGoesThroughNoStep(_ secureInput: Bool) {
        let steps = CorrectionKeySteps(mode: nil, secureInput: secureInput, isShortcut: true)
        #expect(steps == CorrectionKeySteps(mode: nil, secureInput: false, isShortcut: false))
        #expect(steps.shortcut == .none)
        #expect(steps.tracking == .none)
        #expect(!steps.automatic)
    }

    @Test(arguments: [CorrectionMode.manual, .automatic])
    func theShortcutRequestsAFix(_ mode: CorrectionMode) {
        #expect(CorrectionKeySteps(mode: mode, secureInput: false, isShortcut: true).shortcut == .requestFix)
    }

    /// Every other key is followed for the shortcut; only the automatic route sees it too.
    @Test func otherKeysAreTrackedInEveryRoute() {
        let manual = CorrectionKeySteps(mode: .manual, secureInput: false, isShortcut: false)
        #expect(manual.shortcut == .none)
        #expect(manual.tracking == .track)
        #expect(!manual.automatic)
        let automatic = CorrectionKeySteps(mode: .automatic, secureInput: false, isShortcut: false)
        #expect(automatic.tracking == .track)
        #expect(automatic.automatic)
    }

    /// A password prompt is never fixed and its keys are not remembered; the
    /// shortcut goes to the app. The automatic route checks secure input itself.
    @Test func secureInputSkipsTheShortcutAndForgetsTheWord() {
        let shortcut = CorrectionKeySteps(mode: .manual, secureInput: true, isShortcut: true)
        #expect(shortcut.shortcut == .skippedForSecureInput)
        #expect(shortcut.tracking == .interrupt)
        let key = CorrectionKeySteps(mode: .automatic, secureInput: true, isShortcut: false)
        #expect(key.shortcut == .none)
        #expect(key.tracking == .interrupt)
        #expect(key.automatic)
    }
}
