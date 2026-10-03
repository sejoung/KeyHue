import Testing
@testable import KeyHueCore

private extension InputSourceAction {
    /// 자동 선택(ABC → U.S. → 첫 영문 배열)으로의 전환.
    static let auto = InputSourceAction.selectDefault(preferredID: nil)
}

@Suite("App switch reset")
struct AppSwitchPolicyTests {
    private func settings(_ onAppSwitch: SwitchBehavior = .keep) -> KeyHueSettings {
        var s = KeyHueSettings()
        s.onAppSwitch = onAppSwitch
        return s
    }

    @Test func koreanToABCOnSwitch() {
        let action = ResetPolicy.onAppActivated(bundleID: "com.microsoft.VSCode", settings: settings(.switchToDefault), remembered: [:], current: .korean2Set)
        #expect(action == .auto)
    }

    @Test func englishStaysOnSwitch() {
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: settings(.switchToDefault), remembered: [:], current: .abc) == .none)
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: settings(.switchToDefault), remembered: [:], current: .us) == .none)
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: settings(.switchToDefault), remembered: [:], current: .german) == .none)
    }

    @Test func explicitDefaultSourceMustMatchExactly() {
        var s = settings(.switchToDefault)
        s.defaultSourceID = InputSourceInfo.german.id
        let target = InputSourceAction.selectDefault(preferredID: InputSourceInfo.german.id)
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: s, remembered: [:], current: .abc) == target)
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: s, remembered: [:], current: .korean2Set) == target)
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: s, remembered: [:], current: .german) == .none)
    }

    @Test func nonKoreanNativeScriptsAlsoReset() {
        for current in [InputSourceInfo.hiragana, .pinyin, .russian, .japaneseRoman] {
            #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: settings(.switchToDefault), remembered: [:], current: current) == .auto)
        }
    }

    @Test func optionOffDoesNothing() {
        #expect(ResetPolicy.onAppActivated(bundleID: "a", settings: settings(), remembered: [:], current: .korean2Set) == .none)
    }

    @Test func rememberedSourceWinsOverReset() {
        let remembered = ["com.tinyspeck.slackmacgap": InputSourceInfo.korean2Set.id]
        let action = ResetPolicy.onAppActivated(
            bundleID: "com.tinyspeck.slackmacgap",
            settings: settings(.restoreLast),
            remembered: remembered,
            current: .abc
        )
        #expect(action == .select(sourceID: InputSourceInfo.korean2Set.id))
    }

    @Test func rememberedSourceAlreadyActive() {
        let remembered = ["com.apple.Terminal": InputSourceInfo.abc.id]
        let action = ResetPolicy.onAppActivated(bundleID: "com.apple.Terminal", settings: settings(.restoreLast), remembered: remembered, current: .abc)
        #expect(action == .none)
    }

    @Test func unknownAppFallsBackToReset() {
        let action = ResetPolicy.onAppActivated(bundleID: "new.app", settings: settings(.restoreLast), remembered: [:], current: .korean2Set)
        #expect(action == .auto)
    }

    @Test func rememberIgnoredWhenDisabled() {
        let remembered = ["a": InputSourceInfo.korean2Set.id]
        let action = ResetPolicy.onAppActivated(bundleID: "a", settings: settings(.switchToDefault), remembered: remembered, current: .korean2Set)
        #expect(action == .auto)
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
        #expect(ResetPolicy.onKeyDown(keyCode: 53, isAutoRepeat: false, settings: enabled, current: .korean2Set) == .auto)
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
        #expect(ResetPolicy.onKeyDown(keyCode: 53, isAutoRepeat: false, settings: enabled, current: .hiragana) == .auto)
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
        #expect(ResetPolicy.onFocusChanged(wasTextInput: true, isTextInput: false, settings: enabled, current: .korean2Set) == .auto)
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

@Suite("Default input source picker")
struct DefaultInputSourcePickerTests {
    @Test func emptyCandidatesHaveNoDefault() {
        #expect(DefaultInputSourcePicker.pick(from: []) == nil)
        #expect(DefaultInputSourcePicker.pick(from: [], preferredID: InputSourceInfo.abc.id) == nil)
    }

    @Test func missingRestoreUsesExplicitDefaultEvenWithoutLatinLayout() {
        let action = DefaultInputSourcePicker.resolve(
            .select(sourceID: "removed"), from: [.korean2Set, .hiragana], current: .korean2Set,
            preferredDefaultID: InputSourceInfo.hiragana.id
        )
        #expect(action == .selectDefault(preferredID: InputSourceInfo.hiragana.id))
    }

    @Test func missingRestoreAndMissingDefaultUseAutomatic() {
        #expect(DefaultInputSourcePicker.resolve(
            .select(sourceID: "removed"), from: [.us, .korean2Set], current: .korean2Set,
            preferredDefaultID: "also.removed"
        ) == .selectDefault(preferredID: nil))
    }

    @Test func missingPreferredDoesNotReplaceAnActiveLatinLayout() {
        #expect(DefaultInputSourcePicker.resolve(
            .selectDefault(preferredID: "removed"), from: [.abc, .german], current: .german,
            preferredDefaultID: nil
        ) == .none)
    }

    @Test func noFallbackPreservesInputInsteadOfSelectingUnavailableSource() {
        for sources in [[], [InputSourceInfo.korean2Set, .hiragana]] {
            for action in [InputSourceAction.select(sourceID: "removed"), .selectDefault(preferredID: nil), .selectDefault(preferredID: "removed")] {
                #expect(DefaultInputSourcePicker.resolve(action, from: sources, current: .korean2Set, preferredDefaultID: nil) == .none)
            }
        }
    }

    @Test func prefersABC() {
        #expect(DefaultInputSourcePicker.pick(from: [.korean2Set, .us, .abc]) == .abc)
    }

    @Test func fallsBackToUS() {
        #expect(DefaultInputSourcePicker.pick(from: [.korean2Set, .dvorak, .us]) == .us)
    }

    @Test func fallsBackToAnyLatinKeyLayout() {
        #expect(DefaultInputSourcePicker.pick(from: [.russian, .german]) == .german)
        #expect(DefaultInputSourcePicker.pick(from: [.korean2Set, .dvorak]) == .dvorak)
    }

    @Test func japaneseRomanModeIsNotChosenAutomatically() {
        #expect(DefaultInputSourcePicker.pick(from: [.hiragana, .japaneseRoman]) == nil)
    }

    @Test func noLatinSource() {
        #expect(DefaultInputSourcePicker.pick(from: [.korean2Set, .hiragana]) == nil)
    }

    @Test func honorsPreferredWhenEnabled() {
        #expect(DefaultInputSourcePicker.pick(from: [.abc, .german], preferredID: InputSourceInfo.german.id) == .german)
        #expect(DefaultInputSourcePicker.pick(from: [.hiragana, .japaneseRoman], preferredID: InputSourceInfo.japaneseRoman.id) == .japaneseRoman)
    }

    @Test func preferredMissingFallsBackToAutomatic() {
        #expect(DefaultInputSourcePicker.pick(from: [.abc, .korean2Set], preferredID: InputSourceInfo.german.id) == .abc)
    }
}

@Suite("Switch verification")
struct SwitchVerificationTests {
    @Test func automaticIsSatisfiedByAnyLatinSource() {
        #expect(ResetPolicy.isSatisfied(.auto, by: .abc))
        #expect(ResetPolicy.isSatisfied(.auto, by: .german))
        #expect(!ResetPolicy.isSatisfied(.auto, by: .korean2Set))
        #expect(!ResetPolicy.isSatisfied(.auto, by: nil))
    }

    @Test func preferredRequiresExactSource() {
        let action = InputSourceAction.selectDefault(preferredID: InputSourceInfo.german.id)
        #expect(ResetPolicy.isSatisfied(action, by: .german))
        #expect(!ResetPolicy.isSatisfied(action, by: .abc))
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

@Suite("Reset policy edge cases")
struct ResetPolicyEdgeCaseTests {
    private func restoring(window: SwitchBehavior = .keep) -> KeyHueSettings {
        var s = KeyHueSettings()
        s.onAppSwitch = .restoreLast
        s.onWindowSwitch = window
        return s
    }

    @Test func appWithoutBundleIDUsesTheFrontWindowThenTheDefault() {
        // Bundle ID가 없는 앱(일부 도우미 프로세스)은 앱 기록을 찾을 수 없다
        let remembered = ["": InputSourceInfo.hiragana.id]
        #expect(ResetPolicy.onAppActivated(bundleID: nil, settings: restoring(), remembered: remembered, current: .korean2Set) == .auto)
        #expect(ResetPolicy.onAppActivated(
            bundleID: nil, settings: restoring(window: .restoreLast), remembered: remembered,
            rememberedForWindow: InputSourceInfo.german.id, current: .korean2Set
        ) == .select(sourceID: InputSourceInfo.german.id))
    }

    @Test func unavailableFrontWindowAndAppMemoryFallBackToTheDefault() {
        let action = ResetPolicy.onAppActivated(
            bundleID: "a", settings: restoring(window: .restoreLast), remembered: ["a": "removed.app"],
            rememberedForWindow: "removed.window", current: .korean2Set,
            availableSourceIDs: [InputSourceInfo.abc.id, InputSourceInfo.korean2Set.id]
        )
        #expect(action == .auto)
    }

    @Test func availableFrontWindowWinsEvenWhenItIsTheCurrentSource() {
        // 앞 창 기록이 지금 Source와 같으면 앱 기록으로 넘어가지 않고 아무것도 하지 않는다
        let action = ResetPolicy.onAppActivated(
            bundleID: "a", settings: restoring(window: .restoreLast), remembered: ["a": InputSourceInfo.hiragana.id],
            rememberedForWindow: InputSourceInfo.korean2Set.id, current: .korean2Set,
            availableSourceIDs: [InputSourceInfo.hiragana.id, InputSourceInfo.korean2Set.id]
        )
        #expect(action == .none)
    }
}

@Suite("Default input source picker edge cases")
struct DefaultInputSourcePickerEdgeCaseTests {
    /// 사용자가 만든 영문 배열(Ukelele 등). keylayout 접두어가 없다.
    private let customLatin = InputSourceInfo(
        id: "org.sil.ukelele.keyboardlayout.custom.custom", localizedName: "Custom", languages: ["en"], isASCIICapable: true
    )

    @Test func nonKeyLayoutLatinSourceIsUsedOnlyWithoutASystemKeyLayout() {
        #expect(DefaultInputSourcePicker.pick(from: [.korean2Set, customLatin]) == customLatin)
        #expect(DefaultInputSourcePicker.pick(from: [customLatin, .german]) == .german)
        #expect(DefaultInputSourcePicker.pick(from: [customLatin, .dvorak, .us]) == .us)
    }

    @Test func removedCurrentLatinLayoutIsNotTreatedAsAlreadyThere() {
        // 지금 쓰던 영문 배열(German)이 방금 꺼졌다면, 켜져 있는 영문 배열로 바꾼다
        #expect(DefaultInputSourcePicker.resolve(
            .selectDefault(preferredID: nil), from: [.abc, .korean2Set], current: .german, preferredDefaultID: nil
        ) == .selectDefault(preferredID: nil))
    }

    @Test func removedRestoreTargetKeepsAnActiveLatinLayout() {
        // 복원 대상이 사라져 자동 선택으로 대체될 때, 이미 켜져 있는 영문 배열이면 그대로 둔다
        #expect(DefaultInputSourcePicker.resolve(
            .select(sourceID: "removed"), from: [.abc, .german], current: .german, preferredDefaultID: nil
        ) == .none)
    }

    @Test func availableTargetsAreKeptAsRequested() {
        let sources: [InputSourceInfo] = [.abc, .german, .hiragana]
        for action in [InputSourceAction.select(sourceID: InputSourceInfo.hiragana.id),
                       .selectDefault(preferredID: InputSourceInfo.german.id)] {
            #expect(DefaultInputSourcePicker.resolve(action, from: sources, current: .korean2Set, preferredDefaultID: nil) == action)
        }
        #expect(DefaultInputSourcePicker.resolve(.none, from: sources, current: .korean2Set, preferredDefaultID: nil) == .none)
    }
}
