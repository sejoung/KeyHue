import Testing
@testable import KeyHueCore

@Suite("App switch reset")
struct AppSwitchPolicyTests {
    private func settings(appSwitch: Bool = false, remember: Bool = false) -> KeyHueSettings {
        var s = KeyHueSettings()
        s.resetOnAppSwitch = appSwitch
        s.rememberInputPerApp = remember
        return s
    }

    @Test func koreanToABCOnSwitch() {
        let action = ResetPolicy.onAppActivated(bundleID: "com.microsoft.VSCode", settings: settings(appSwitch: true), remembered: [:], current: .korean2Set)
        #expect(action == .selectABC)
    }

    @Test func englishStaysOnSwitch() {
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: settings(appSwitch: true), remembered: [:], current: .abc) == .none)
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: settings(appSwitch: true), remembered: [:], current: .us) == .none)
    }

    @Test func optionOffDoesNothing() {
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: settings(), remembered: [:], current: .korean2Set) == .none)
    }

    @Test func rememberedSourceWinsOverReset() {
        let remembered = ["com.tinyspeck.slackmacgap": InputSourceInfo.korean2Set.id]
        let action = ResetPolicy.onAppActivated(
            bundleID: "com.tinyspeck.slackmacgap",
            settings: settings(appSwitch: true, remember: true),
            remembered: remembered,
            current: .abc
        )
        #expect(action == .select(sourceID: InputSourceInfo.korean2Set.id))
    }

    @Test func rememberedSourceAlreadyActive() {
        let remembered = ["com.apple.Terminal": InputSourceInfo.abc.id]
        let action = ResetPolicy.onAppActivated(bundleID: "com.apple.Terminal", settings: settings(remember: true), remembered: remembered, current: .abc)
        #expect(action == .none)
    }

    @Test func unknownAppFallsBackToReset() {
        let action = ResetPolicy.onAppActivated(bundleID: "new.app", settings: settings(appSwitch: true, remember: true), remembered: [:], current: .korean2Set)
        #expect(action == .selectABC)
    }

    @Test func rememberIgnoredWhenDisabled() {
        let remembered = ["a": InputSourceInfo.korean2Set.id]
        let action = ResetPolicy.onAppActivated(bundleID: "a", settings: settings(appSwitch: true), remembered: remembered, current: .korean2Set)
        #expect(action == .selectABC)
    }
}

@Suite("ESC reset")
struct EscapePolicyTests {
    private var enabled: KeyHueSettings {
        var s = KeyHueSettings()
        s.resetOnEscape = true
        return s
    }

    @Test func escapeSwitchesKoreanToABC() {
        #expect(ResetPolicy.onKeyDown(keyCode: 53, isAutoRepeat: false, settings: enabled, current: .korean2Set) == .selectABC)
    }

    @Test func otherKeysIgnored() {
        #expect(ResetPolicy.onKeyDown(keyCode: 0, isAutoRepeat: false, settings: enabled, current: .korean2Set) == .none)
    }

    @Test func autoRepeatIgnored() {
        #expect(ResetPolicy.onKeyDown(keyCode: 53, isAutoRepeat: true, settings: enabled, current: .korean2Set) == .none)
    }

    @Test func optionOffDoesNothing() {
        #expect(ResetPolicy.onKeyDown(keyCode: 53, isAutoRepeat: false, settings: KeyHueSettings(), current: .korean2Set) == .none)
    }

    @Test func alreadyEnglish() {
        #expect(ResetPolicy.onKeyDown(keyCode: 53, isAutoRepeat: false, settings: enabled, current: .abc) == .none)
    }

    @Test func unknownSourceStillResets() {
        #expect(ResetPolicy.onKeyDown(keyCode: 53, isAutoRepeat: false, settings: enabled, current: .japaneseKana) == .selectABC)
    }
}

@Suite("Text focus reset")
struct TextFocusPolicyTests {
    private var enabled: KeyHueSettings {
        var s = KeyHueSettings()
        s.resetOnTextFocusLoss = true
        return s
    }

    @Test func leavingTextField() {
        #expect(ResetPolicy.onFocusChanged(wasTextInput: true, isTextInput: false, settings: enabled, current: .korean2Set) == .selectABC)
    }

    @Test func movingBetweenTextFields() {
        #expect(ResetPolicy.onFocusChanged(wasTextInput: true, isTextInput: true, settings: enabled, current: .korean2Set) == .none)
    }

    @Test func enteringTextField() {
        #expect(ResetPolicy.onFocusChanged(wasTextInput: false, isTextInput: true, settings: enabled, current: .korean2Set) == .none)
    }

    @Test func optionOff() {
        #expect(ResetPolicy.onFocusChanged(wasTextInput: true, isTextInput: false, settings: KeyHueSettings(), current: .korean2Set) == .none)
    }

    @Test func roles() {
        #expect(TextInputRole.isTextInput(role: "AXTextField", subrole: nil))
        #expect(TextInputRole.isTextInput(role: "AXTextArea", subrole: nil))
        #expect(TextInputRole.isTextInput(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(TextInputRole.isTextInput(role: "AXGroup", subrole: nil, isEditable: true))
        #expect(!TextInputRole.isTextInput(role: "AXButton", subrole: nil))
        #expect(!TextInputRole.isTextInput(role: nil, subrole: nil))
    }
}

@Suite("ABC source picker")
struct ABCSourcePickerTests {
    @Test func prefersABC() {
        #expect(ABCSourcePicker.pick(from: [.korean2Set, .us, .abc]) == .abc)
    }

    @Test func fallsBackToUS() {
        #expect(ABCSourcePicker.pick(from: [.korean2Set, .dvorak, .us]) == .us)
    }

    @Test func fallsBackToAnyEnglishKeyLayout() {
        #expect(ABCSourcePicker.pick(from: [.korean2Set, .dvorak]) == .dvorak)
    }

    @Test func noEnglishSource() {
        #expect(ABCSourcePicker.pick(from: [.korean2Set, .japaneseKana]) == nil)
    }
}

@Suite("Switch verification")
struct SwitchVerificationTests {
    @Test func selectABCIsSatisfiedByAnyEnglishSource() {
        #expect(ResetPolicy.isSatisfied(.selectABC, by: .abc))
        #expect(ResetPolicy.isSatisfied(.selectABC, by: .us))
        #expect(!ResetPolicy.isSatisfied(.selectABC, by: .korean2Set))
        #expect(!ResetPolicy.isSatisfied(.selectABC, by: nil))
    }

    @Test func selectByIDRequiresExactSource() {
        let action = InputSourceAction.select(sourceID: InputSourceInfo.korean2Set.id)
        #expect(ResetPolicy.isSatisfied(action, by: .korean2Set))
        #expect(!ResetPolicy.isSatisfied(action, by: .gureumHan))
    }

    @Test func noneIsAlwaysSatisfied() {
        #expect(ResetPolicy.isSatisfied(.none, by: nil))
    }
}
