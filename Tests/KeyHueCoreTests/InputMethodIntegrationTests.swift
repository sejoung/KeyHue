import Foundation
import Testing
@testable import KeyHueCore

extension InputSourceInfo {
    static let keyHueHangul = InputSourceInfo(id: InputMethodIntegration.hangulID, localizedName: "KeyHue Korean", languages: ["ko"], isASCIICapable: false)
    static let keyHueLatin = InputSourceInfo(id: InputMethodIntegration.latinID, localizedName: "KeyHue English", languages: ["en"], isASCIICapable: true)
}

private let korean3Set = InputSourceInfo(id: "com.apple.inputmethod.Korean.3SetKorean", localizedName: "3-Set Korean", languages: ["ko"], isASCIICapable: false)

@MainActor
private final class IntegrationHarness {
    var settings = KeyHueSettings()
    let switcher = FakeSwitcher(current: .abc)
    let scheduler = FakeScheduler()
    let memory = AppInputMemory(defaults: makeTestDefaults())
    var routingEnabled = true
    var suspensions = 0
    lazy var reset = AutoResetCoordinator(switcher: switcher, scheduler: scheduler, memory: memory) { [unowned self] in self.settings }
    lazy var router: InputMethodRoutingCoordinator = {
        let router = InputMethodRoutingCoordinator(switcher: switcher, scheduler: scheduler) { [unowned self] in self.routingEnabled }
        router.onSuspend = { [unowned self] in self.suspensions += 1; self.routingEnabled = false }
        return router
    }()
    init() {
        settings.integrateInputMethod = true
        settings.onAppSwitch = .switchToDefault
        switcher.known += [.keyHueHangul, .keyHueLatin]
    }
    func activate() {
        reset.appActivated(previousBundleID: nil, currentBundleID: "target", sourceBeforeActivation: switcher.currentSource)
        scheduler.advance(by: 0.04)
    }
    func observe(_ source: InputSourceInfo) {
        switcher.currentSource = source
        router.sourceChanged(to: source)
    }
}

@MainActor
@Suite("Input method integration")
struct InputMethodIntegrationTests {
    @Test(arguments: [Optional<String>.none, InputMethodIntegration.abcID])
    func automaticAndABCDefaultsUseLatinWithoutChangingSavedPreference(_ saved: String?) {
        let h = IntegrationHarness()
        h.settings.defaultSourceID = saved
        h.activate()
        #expect(h.switcher.currentSource == .keyHueLatin)
        #expect(h.settings.defaultSourceID == saved)
        h.settings.integrateInputMethod = false
        h.switcher.currentSource = .keyHueHangul
        h.activate()
        #expect(h.switcher.currentSource == .abc)
    }

    @Test(arguments: [InputSourceInfo.us, .german, .hiragana])
    func explicitOtherDefaultsRemainRespected(_ saved: InputSourceInfo) {
        let h = IntegrationHarness()
        h.settings.defaultSourceID = saved.id
        h.activate()
        #expect(h.switcher.currentSource == saved)
    }

    @Test func rememberedABCIsTranslatedOnlyWhenReadingMemory() {
        let h = IntegrationHarness()
        h.settings.onAppSwitch = .restoreLast
        h.memory.record(sourceID: InputMethodIntegration.abcID, for: "target")
        h.activate() // Already ABC must still switch to the effective remembered target.
        #expect(h.switcher.currentSource == .keyHueLatin)
        #expect(h.memory.entries["target"] == InputMethodIntegration.abcID)
    }

    // Memory recorded before integration holds the system 2-Set Korean. Restoring
    // it verbatim selected the system input method instead of KeyHue's.
    @Test func rememberedSystemKoreanRestoresKeyHueHangulWhileIntegrated() {
        let h = IntegrationHarness()
        h.settings.onAppSwitch = .restoreLast
        h.memory.record(sourceID: InputSourceInfo.korean2Set.id, for: "target")
        h.switcher.currentSource = .keyHueLatin
        h.activate()
        #expect(h.switcher.currentSource == .keyHueHangul)
        #expect(h.memory.entries["target"] == InputSourceInfo.korean2Set.id)
    }

    @Test func windowMemoryOfSystemKoreanRestoresKeyHueHangulWhileIntegrated() {
        let h = IntegrationHarness()
        h.settings.onWindowSwitch = .restoreLast
        h.reset.sourceChanged(from: nil, to: .korean2Set, activeBundleID: nil, activeWindow: AnyHashable("window"))
        h.switcher.currentSource = .keyHueLatin
        h.reset.windowSwitched(to: AnyHashable("window"), current: .keyHueLatin)
        h.scheduler.advance(by: 0.04)
        #expect(h.switcher.currentSource == .keyHueHangul)
    }

    @Test func systemKoreanDefaultUsesKeyHueHangulWithoutChangingSavedPreference() {
        let h = IntegrationHarness()
        h.settings.defaultSourceID = InputSourceInfo.korean2Set.id
        h.activate()
        #expect(h.switcher.currentSource == .keyHueHangul)
        #expect(h.settings.defaultSourceID == InputSourceInfo.korean2Set.id)
    }

    /// Removing Latin leaves KeyHue Hangul selectable, so only the revert keeps the system source.
    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func systemKoreanDefaultFallsBackToItselfWhenTheModeDisappearsBeforeExecution(_ removed: String) {
        let h = IntegrationHarness()
        h.settings.defaultSourceID = InputSourceInfo.korean2Set.id
        h.settings.resetOnEscape = true
        // ESC resolves the effective default now and selects it on the next turn.
        h.reset.keyDown(keyCode: 53, isAutoRepeat: false, current: .abc)
        h.switcher.known.removeAll { $0.id == removed }
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed == [.selectDefault(preferredID: InputSourceInfo.korean2Set.id)])
    }

    /// Same revert for the automatic/ABC default resolved as KeyHue Latin while Latin itself stays enabled.
    @Test(arguments: [Optional<String>.none, InputMethodIntegration.abcID])
    func automaticOrABCDefaultRevertsWhenThePairDisappearsBeforeExecution(_ saved: String?) {
        let h = IntegrationHarness()
        h.settings.defaultSourceID = saved
        h.settings.resetOnEscape = true
        h.switcher.currentSource = .korean2Set
        h.reset.keyDown(keyCode: 53, isAutoRepeat: false, current: .korean2Set)
        h.switcher.known.removeAll { $0.id == InputMethodIntegration.hangulID }
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed == [.selectDefault(preferredID: saved)])
    }

    @Test(arguments: [false, true])
    func windowMemoryOfKeyHueModesRestoresSystemPairWithoutIntegration(_ modeRemoved: Bool) {
        let window = AnyHashable("window")
        for (remembered, expected) in [(InputSourceInfo.keyHueHangul, InputSourceInfo.korean2Set), (.keyHueLatin, .abc)] {
            let h = IntegrationHarness()
            h.settings.onWindowSwitch = .restoreLast
            h.reset.sourceChanged(from: nil, to: remembered, activeBundleID: nil, activeWindow: window)
            if modeRemoved { h.switcher.known.removeAll { $0.id == InputMethodIntegration.latinID } } else { h.settings.integrateInputMethod = false }
            h.switcher.currentSource = .hiragana
            h.reset.windowSwitched(to: window, current: .hiragana)
            h.scheduler.advance(by: 0.04)
            #expect(h.switcher.currentSource == expected)
            #expect(h.switcher.performed == [.select(sourceID: expected.id)])
            #expect(h.reset.windowMemory.source(for: window) == remembered.id)
        }
    }

    @Test func windowMemoryIsNotRewrittenWhenReadAsKeyHueMode() {
        let window = AnyHashable("window")
        for (remembered, expected) in [(InputSourceInfo.korean2Set, InputSourceInfo.keyHueHangul), (.abc, .keyHueLatin)] {
            let h = IntegrationHarness()
            h.settings.onWindowSwitch = .restoreLast
            h.reset.sourceChanged(from: nil, to: remembered, activeBundleID: nil, activeWindow: window)
            h.switcher.currentSource = .hiragana
            h.reset.windowSwitched(to: window, current: .hiragana)
            h.scheduler.advance(by: 1)
            #expect(h.switcher.currentSource == expected)
            #expect(h.reset.windowMemory.source(for: window) == remembered.id)
        }
    }

    /// With only one KeyHue mode the pair is unavailable: system memory is restored as recorded,
    /// even when the remaining KeyHue mode would match it.
    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func systemMemoryIsNotTranslatedWhenOnlyOneModeIsEnabled(_ removed: String) {
        for remembered in [InputSourceInfo.korean2Set, .abc] {
            let h = IntegrationHarness()
            h.settings.onAppSwitch = .restoreLast
            h.switcher.known.removeAll { $0.id == removed }
            h.memory.record(sourceID: remembered.id, for: "target")
            h.switcher.currentSource = .hiragana
            h.activate()
            #expect(h.switcher.currentSource == remembered)
            #expect(h.switcher.performed == [.select(sourceID: remembered.id)])
        }
    }

    /// The reverse mapping needs the system counterpart. Without it the KeyHue ID is
    /// kept, so an enabled KeyHue mode is restored as recorded.
    @Test func rememberedKeyHueModeIsKeptWhenSystemCounterpartIsNotEnabled() {
        for remembered in [InputSourceInfo.keyHueHangul, .keyHueLatin] {
            let h = IntegrationHarness()
            h.settings.onAppSwitch = .restoreLast
            h.settings.integrateInputMethod = false
            h.switcher.known.removeAll { $0.id == InputSourceInfo.korean2Set.id || $0.id == InputSourceInfo.abc.id }
            h.memory.record(sourceID: remembered.id, for: "target")
            h.switcher.currentSource = .hiragana
            h.activate()
            #expect(h.switcher.currentSource == remembered)
            #expect(h.memory.entries["target"] == remembered.id)
        }
    }

    /// A removed KeyHue mode without its system counterpart follows the deleted-memory rule (default).
    @Test func removedKeyHueModeWithoutSystemCounterpartFallsBackToDefault() {
        let h = IntegrationHarness()
        h.settings.onAppSwitch = .restoreLast
        h.switcher.known.removeAll { $0.id == InputMethodIntegration.latinID || $0.id == InputSourceInfo.abc.id }
        h.memory.record(sourceID: InputMethodIntegration.latinID, for: "target")
        h.switcher.currentSource = .hiragana
        h.activate()
        #expect(h.switcher.currentSource == .us)
        #expect(h.switcher.performed == [.selectDefault(preferredID: nil)])
        #expect(h.memory.entries["target"] == InputMethodIntegration.latinID)
    }

    @Test(arguments: [korean3Set, .gureumHan])
    func otherKoreanSourcesAreNeverTranslated(_ source: InputSourceInfo) {
        let h = IntegrationHarness()
        h.switcher.known.append(source)
        h.settings.onAppSwitch = .restoreLast
        h.memory.record(sourceID: source.id, for: "target")
        h.switcher.currentSource = .keyHueLatin
        h.activate()
        #expect(h.switcher.currentSource == source)

        let d = IntegrationHarness()
        d.switcher.known.append(source)
        d.settings.defaultSourceID = source.id
        d.activate()
        #expect(d.switcher.currentSource == source)
    }

    /// Already on the translated target: no redundant TIS selection in either direction.
    @Test func alreadyOnTheTranslatedTargetDoesNotSwitch() {
        let cases: [(integrated: Bool, remembered: InputSourceInfo, current: InputSourceInfo)] = [
            (true, .korean2Set, .keyHueHangul),
            (true, .abc, .keyHueLatin),
            (false, .keyHueHangul, .korean2Set),
            (false, .keyHueLatin, .abc)
        ]
        for c in cases {
            let h = IntegrationHarness()
            h.settings.onAppSwitch = .restoreLast
            h.settings.integrateInputMethod = c.integrated
            h.memory.record(sourceID: c.remembered.id, for: "target")
            h.switcher.currentSource = c.current
            h.activate()
            h.scheduler.advance(by: 1)
            #expect(h.switcher.performed.isEmpty)
            #expect(h.switcher.currentSource == c.current)
        }
    }

    @Test func systemKoreanDefaultIsSatisfiedByKeyHueHangul() {
        let h = IntegrationHarness()
        h.settings.defaultSourceID = InputSourceInfo.korean2Set.id
        h.settings.resetOnEscape = true
        h.settings.resetOnTextFocusLoss = true
        h.switcher.currentSource = .keyHueHangul
        h.reset.keyDown(keyCode: 53, isAutoRepeat: false, current: .keyHueHangul)
        h.reset.focusChanged(wasTextInput: true, isTextInput: false, current: .keyHueHangul)
        h.activate()
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
    }

    @Test func windowMemoryWinsOverAppMemoryAfterTranslation() {
        let h = IntegrationHarness()
        h.settings.onAppSwitch = .restoreLast
        h.settings.onWindowSwitch = .restoreLast
        h.memory.record(sourceID: InputSourceInfo.abc.id, for: "target")
        h.reset.sourceChanged(from: nil, to: .korean2Set, activeBundleID: nil, activeWindow: AnyHashable("front"))
        h.switcher.currentSource = .hiragana
        h.reset.appActivated(previousBundleID: nil, currentBundleID: "target", sourceBeforeActivation: .hiragana,
                             currentWindow: { AnyHashable("front") })
        h.scheduler.advance(by: 0.04)
        #expect(h.switcher.currentSource == .keyHueHangul)
        #expect(h.switcher.performed == [.select(sourceID: InputMethodIntegration.hangulID)])
    }

    /// An untranslatable, removed window entry does not hide a usable app entry.
    @Test func unavailableWindowMemoryFallsThroughToAppMemory() {
        let h = IntegrationHarness()
        h.settings.onAppSwitch = .restoreLast
        h.settings.onWindowSwitch = .restoreLast
        h.memory.record(sourceID: InputSourceInfo.abc.id, for: "target")
        h.reset.sourceChanged(from: nil, to: .keyHueHangul, activeBundleID: nil, activeWindow: AnyHashable("front"))
        // KeyHue uninstalled and system 2-Set Korean disabled.
        h.switcher.known.removeAll { [InputMethodIntegration.hangulID, InputMethodIntegration.latinID, InputSourceInfo.korean2Set.id].contains($0.id) }
        h.switcher.currentSource = .hiragana
        h.reset.appActivated(previousBundleID: nil, currentBundleID: "target", sourceBeforeActivation: .hiragana,
                             currentWindow: { AnyHashable("front") })
        h.scheduler.advance(by: 0.04)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed == [.select(sourceID: InputSourceInfo.abc.id)])
    }

    /// The override retry re-reads the roster: a lost pair makes the retry target the system source.
    @Test func overrideRetryAfterThePairDisappearsUsesTheSystemSource() {
        let h = IntegrationHarness()
        h.settings.onAppSwitch = .restoreLast
        h.memory.record(sourceID: InputSourceInfo.korean2Set.id, for: "target")
        h.switcher.currentSource = .hiragana
        h.activate()
        #expect(h.switcher.currentSource == .keyHueHangul)
        h.switcher.known.removeAll { $0.id == InputMethodIntegration.latinID }
        h.switcher.currentSource = .korean2Set
        h.reset.sourceChanged(from: .keyHueHangul, to: .korean2Set, activeBundleID: "target")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed == [.select(sourceID: InputMethodIntegration.hangulID)])
        #expect(h.memory.entries["target"] == InputSourceInfo.korean2Set.id)
    }

    @Test func failingHangulFallsBackToSavedSystemKoreanDefault() {
        let h = IntegrationHarness()
        h.settings.defaultSourceID = InputSourceInfo.korean2Set.id
        h.switcher.failingSourceIDs = [InputMethodIntegration.hangulID]
        h.activate()
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed == [
            .selectDefault(preferredID: InputMethodIntegration.hangulID),
            .selectDefault(preferredID: InputSourceInfo.korean2Set.id)
        ])
        #expect(h.scheduler.pendingCount == 0)
    }

    /// Restoring a translated memory that fails uses the saved default, not the remembered system source.
    @Test func failingRestoredModeFallsBackToSavedDefault() {
        let h = IntegrationHarness()
        h.settings.onAppSwitch = .restoreLast
        h.memory.record(sourceID: InputSourceInfo.korean2Set.id, for: "target")
        h.switcher.failingSourceIDs = [InputMethodIntegration.hangulID]
        h.switcher.currentSource = .hiragana
        h.activate()
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed == [.select(sourceID: InputMethodIntegration.hangulID), .selectDefault(preferredID: nil)])
        #expect(h.memory.entries["target"] == InputSourceInfo.korean2Set.id)
    }

    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func failingExplicitKeyHueDefaultFallsBackToAutomatic(_ saved: String) {
        let h = IntegrationHarness()
        h.settings.defaultSourceID = saved
        h.switcher.failingSourceIDs = [saved]
        h.switcher.currentSource = .hiragana
        h.activate()
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed == [.selectDefault(preferredID: saved), .selectDefault(preferredID: nil)])
    }

    /// When KeyHue Latin is the only Latin source, the automatic fallback must not land in a KeyHue mode.
    @Test func failureFallbackDoesNotReselectAKeyHueModeAsTheOnlyLatinSource() {
        let h = IntegrationHarness()
        h.switcher.known = [.korean2Set, .hiragana, .keyHueHangul, .keyHueLatin]
        h.switcher.failingSourceIDs = [InputMethodIntegration.latinID]
        h.switcher.currentSource = .korean2Set
        h.activate()
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed == [.selectDefault(preferredID: InputMethodIntegration.latinID)])
    }

    /// A KeyHue mode saved as the default reads as its system counterpart once
    /// integration is paused or the pair is incomplete, like remembered modes.
    @Test(arguments: [false, true])
    func savedKeyHueDefaultReadsAsSystemPairWithoutIntegration(_ modeRemoved: Bool) {
        for (saved, expected) in [(InputSourceInfo.keyHueHangul, InputSourceInfo.korean2Set), (.keyHueLatin, .abc)] {
            let h = IntegrationHarness()
            h.settings.defaultSourceID = saved.id
            if modeRemoved {
                h.switcher.known.removeAll { $0.id == (saved == .keyHueHangul ? InputMethodIntegration.latinID : InputMethodIntegration.hangulID) }
            } else {
                h.settings.integrateInputMethod = false
            }
            h.switcher.currentSource = .hiragana
            h.activate()
            #expect(h.switcher.currentSource == expected)
            #expect(h.settings.defaultSourceID == saved.id)
        }
    }

    /// The reverse: modes remembered while integrated return to the system pair
    /// once integration is paused or a KeyHue mode is removed.
    @Test(arguments: [false, true])
    func rememberedKeyHueModesRestoreSystemPairWithoutIntegration(_ modeRemoved: Bool) {
        for (remembered, expected) in [(InputSourceInfo.keyHueHangul, InputSourceInfo.korean2Set), (.keyHueLatin, .abc)] {
            let h = IntegrationHarness()
            h.settings.onAppSwitch = .restoreLast
            if modeRemoved { h.switcher.known.removeAll { $0.id == InputMethodIntegration.latinID } } else { h.settings.integrateInputMethod = false }
            h.memory.record(sourceID: remembered.id, for: "target")
            h.switcher.currentSource = .hiragana
            h.activate()
            #expect(h.switcher.currentSource == expected)
            #expect(h.memory.entries["target"] == remembered.id)
        }
    }

    @Test func otherRememberedSourcesAreNotTranslated() {
        let h = IntegrationHarness()
        h.settings.onAppSwitch = .restoreLast
        h.memory.record(sourceID: InputSourceInfo.hiragana.id, for: "target")
        h.activate()
        #expect(h.switcher.currentSource == .hiragana)
    }

    @Test func windowMemoryAndEscapeAndFocusUseSameDefault() {
        let h = IntegrationHarness()
        h.settings.onWindowSwitch = .restoreLast
        h.settings.resetOnEscape = true
        h.settings.resetOnTextFocusLoss = true
        h.reset.sourceChanged(from: nil, to: .abc, activeBundleID: nil, activeWindow: AnyHashable("window"))
        h.reset.windowSwitched(to: AnyHashable("window"), current: .abc)
        h.scheduler.advance(by: 0.04)
        #expect(h.switcher.currentSource == .keyHueLatin)
        h.switcher.currentSource = .abc
        h.reset.keyDown(keyCode: 53, isAutoRepeat: false, current: .abc)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .keyHueLatin)
        h.switcher.currentSource = .abc
        h.reset.focusChanged(wasTextInput: true, isTextInput: false, current: .abc)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .keyHueLatin)
    }

    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func missingOrDisabledModeFallsBackToABC(_ removed: String) {
        let h = IntegrationHarness()
        h.switcher.known.removeAll { $0.id == removed }
        h.switcher.currentSource = .korean2Set
        h.activate()
        #expect(h.switcher.currentSource == .abc)
        #expect(!InputMethodIntegration.isAvailable(in: h.switcher.availableSources))
    }

    @Test func windowDecisionUsesRosterAtExecutionTime() {
        let h = IntegrationHarness()
        h.settings.onWindowSwitch = .restoreLast
        h.reset.sourceChanged(from: nil, to: .abc, activeBundleID: nil, activeWindow: AnyHashable("window"))
        h.reset.windowSwitched(to: AnyHashable("window"), current: .abc)
        h.switcher.known.removeAll { $0.id == InputMethodIntegration.hangulID }
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed.isEmpty)
    }

    @Test func pauseCancelsAllPendingAutomaticActionsAndVerification() {
        let h = IntegrationHarness()
        h.settings.onWindowSwitch = .switchToDefault
        h.reset.appActivated(previousBundleID: nil, currentBundleID: "target", sourceBeforeActivation: .abc)
        h.reset.windowSwitched(current: .abc)
        h.settings.integrateInputMethod = false
        h.reset.cancelPendingWork()
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        h.settings.integrateInputMethod = true
        h.activate()
        h.reset.cancelPendingWork()
        h.switcher.currentSource = .abc // Recovery selected ABC.
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed.count == 1)
    }

    @Test func failedSelectionDoesNotScheduleVerificationOrRetryForever() {
        let h = IntegrationHarness()
        h.switcher.currentSource = .korean2Set
        h.switcher.shouldSucceed = false
        h.activate()
        h.scheduler.advance(by: 10)
        #expect(h.switcher.performed == [.selectDefault(preferredID: InputMethodIntegration.latinID), .selectDefault(preferredID: nil)])
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func failingModeFallsBackSuccessfullyAndIsNotRetried() {
        let h = IntegrationHarness()
        h.switcher.currentSource = .keyHueHangul
        h.switcher.failingSourceIDs = [InputMethodIntegration.latinID]
        h.activate()
        #expect(h.switcher.currentSource == .abc)
        h.switcher.currentSource = .korean2Set
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.count == 2)
        #expect(h.switcher.currentSource == .korean2Set)
    }

    @Test func typingCancelsPendingAutomaticActivation() {
        let h = IntegrationHarness()
        h.reset.appActivated(previousBundleID: nil, currentBundleID: "target", sourceBeforeActivation: .abc)
        h.reset.keyDown(keyCode: 0, isAutoRepeat: false, current: .abc)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
    }

    @Test func newAppActivationReplacesPendingWindowAction() {
        let h = IntegrationHarness()
        h.settings.onWindowSwitch = .restoreLast
        h.reset.sourceChanged(from: nil, to: .hiragana, activeBundleID: nil, activeWindow: AnyHashable("window"))
        h.reset.windowSwitched(to: AnyHashable("window"), current: .abc)
        h.reset.appActivated(previousBundleID: nil, currentBundleID: "target", sourceBeforeActivation: .abc)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed == [.selectDefault(preferredID: InputMethodIntegration.latinID)])
    }

    @Test func settingsPersistIndependentlyAndPermissionTurnOffKeepsIntegration() {
        let defaults = makeTestDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(!store.settings.integrateInputMethod && !store.settings.routeInputMethodPair)
        store.update { $0.integrateInputMethod = true; $0.routeInputMethodPair = true; $0.defaultSourceID = InputMethodIntegration.abcID }
        #expect(SettingsStore(defaults: defaults).settings == store.settings)
        #expect(store.settings.watchesKeyboard)
        store.update { PermissionPolicy.disableFeature(needing: .inputMonitoring, in: &$0) }
        #expect(store.settings.integrateInputMethod)
        #expect(!store.settings.routeInputMethodPair && !store.settings.watchesKeyboard)
        store.update { $0.integrateInputMethod = false }
        #expect(defaults.object(forKey: "integrateInputMethod") == nil)
        #expect(defaults.object(forKey: "routeInputMethodPair") == nil)
        #expect(store.settings.defaultSourceID == InputMethodIntegration.abcID)
    }
}

@MainActor
@Suite("Input method source routing")
struct InputMethodRoutingTests {
    @Test(arguments: [(InputSourceInfo.keyHueHangul, InputSourceInfo.keyHueLatin), (.keyHueLatin, .keyHueHangul)])
    func ABCTransitionSelectsOppositeModeAndDuplicateNotificationsDoNotLoop(_ pair: (InputSourceInfo, InputSourceInfo)) {
        let h = IntegrationHarness()
        h.router.reset(current: pair.0)
        h.observe(.abc)
        h.observe(.abc)
        #expect(h.router.isPending)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == pair.1)
        h.observe(pair.1)
        h.observe(pair.1)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed == [.select(sourceID: pair.0.id), .select(sourceID: pair.1.id)])
    }

    /// ⌘Space after a route went back to ABC every time, and every route was an
    /// external selection that Ghostty closed (ADR 0070). Selecting the mode being
    /// left first keeps it as the previous source (ADR 0071).
    @Test func routeSelectsTheModeBeingLeftJustBeforeTheTarget() {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.performed == [.select(sourceID: InputMethodIntegration.hangulID),
                                         .select(sourceID: InputMethodIntegration.latinID)])
        #expect(h.switcher.currentSource == .keyHueLatin)
    }

    /// Notifications of both selections arrive after the route; neither is a new choice.
    @Test func notificationOfTheModeBeingLeftKeepsTheOverwriteGuard() {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 0)
        h.observe(.keyHueHangul)
        h.observe(.keyHueLatin)
        h.observe(.abc) // TSM overwrite
        h.scheduler.advance(by: 1)
        #expect(h.suspensions == 1)
        #expect(h.switcher.performed.count == 2)
    }

    /// 2026-10-06 10:12 and 10:53: the screen lock selected ABC, the route was
    /// overwritten at once and the user's routing option was turned off (ADR 0071).
    @Test func loginWindowAndSecureInputAreNotRouted() {
        #expect(InputMethodIntegration.routesABC(frontBundleID: "com.mitchellh.ghostty", secureInput: false))
        #expect(!InputMethodIntegration.routesABC(frontBundleID: "com.apple.loginwindow", secureInput: false))
        #expect(!InputMethodIntegration.routesABC(frontBundleID: "com.mitchellh.ghostty", secureInput: true))
    }

    @Test func freshShortcutOrMouseInteractionAllowsAnotherToggle() {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 0)
        h.router.interaction(isTyping: false) // Shortcut or menu click, no shortcut mapping.
        h.observe(.abc)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .keyHueHangul)
        #expect(h.suspensions == 0)
    }

    @Test func typingCancelsPendingSwitchWithoutTouchingTypedText() {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.router.interaction(isTyping: true)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func typingBeforeDelayedSourceNotificationPreventsMidWordSwitch() {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.switcher.currentSource = .abc // TIS changed before notification delivery.
        h.router.interaction(isTyping: true)
        h.observe(.abc)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
    }

    @Test func immediateSystemOverwriteSuspendsInsteadOfOscillating() {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 0)
        h.observe(.abc)
        h.scheduler.advance(by: 1)
        #expect(h.suspensions == 1)
        #expect(h.switcher.performed.count == 2)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func selectionFailureSuspendsAndDoesNotRetry() {
        let h = IntegrationHarness()
        h.switcher.shouldSucceed = false
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 1)
        h.observe(.keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 1)
        #expect(h.suspensions == 1)
        #expect(h.switcher.performed.count == 2)
    }

    @Test(arguments: [InputSourceInfo.hiragana, .german, .korean2Set])
    func otherSourcesAreNeverRedirected(_ source: InputSourceInfo) {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.observe(source)
        h.observe(.abc)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
    }

    @Test func newerSourceChoiceAndContextChangeCancelStaleRoute() {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.observe(.hiragana)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.router.reset(current: .abc) // App/focus/Space changed or integration paused.
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
    }

    @Test func removedModeOrRevokedPermissionStopsPendingRoute() {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.switcher.known.removeAll { $0.id == InputMethodIntegration.latinID }
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        h.switcher.known.append(.keyHueLatin)
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.routingEnabled = false
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
    }
}

@Suite("Input method source mapping")
struct InputMethodSourceMappingTests {
    private static let all: [InputSourceInfo] = [.abc, .us, .korean2Set, korean3Set, .gureumHan, .hiragana, .keyHueHangul, .keyHueLatin]

    private static func settings(integrated: Bool, defaultID: String? = nil) -> KeyHueSettings {
        var settings = KeyHueSettings()
        settings.integrateInputMethod = integrated
        settings.defaultSourceID = defaultID
        return settings
    }

    private static func without(_ ids: String...) -> [InputSourceInfo] {
        all.filter { !ids.contains($0.id) }
    }

    @Test func integratedPairTranslatesOnlyABCAndSystem2Set() {
        let settings = Self.settings(integrated: true)
        let expected: [String: String] = [
            InputSourceInfo.abc.id: InputMethodIntegration.latinID,
            InputSourceInfo.korean2Set.id: InputMethodIntegration.hangulID,
            InputMethodIntegration.latinID: InputMethodIntegration.latinID,
            InputMethodIntegration.hangulID: InputMethodIntegration.hangulID,
            InputSourceInfo.us.id: InputSourceInfo.us.id,
            korean3Set.id: korean3Set.id,
            InputSourceInfo.gureumHan.id: InputSourceInfo.gureumHan.id,
            InputSourceInfo.hiragana.id: InputSourceInfo.hiragana.id,
            "removed": "removed"
        ]
        for (raw, mapped) in expected {
            #expect(InputMethodIntegration.sourceID(raw, settings: settings, sources: Self.all) == mapped)
        }
    }

    /// Integration off, or on with only one mode: KeyHue IDs read as the enabled system pair, nothing else changes.
    @Test(arguments: [false, true])
    func withoutThePairKeyHueModesReadAsSystemSources(_ integrated: Bool) {
        let settings = Self.settings(integrated: integrated)
        let sources = integrated ? Self.without(InputMethodIntegration.latinID) : Self.all
        let expected: [String: String] = [
            InputMethodIntegration.hangulID: InputSourceInfo.korean2Set.id,
            InputMethodIntegration.latinID: InputSourceInfo.abc.id,
            InputSourceInfo.abc.id: InputSourceInfo.abc.id,
            InputSourceInfo.korean2Set.id: InputSourceInfo.korean2Set.id,
            korean3Set.id: korean3Set.id
        ]
        for (raw, mapped) in expected {
            #expect(InputMethodIntegration.sourceID(raw, settings: settings, sources: sources) == mapped)
        }
    }

    @Test func reverseMappingKeepsKeyHueIDWithoutTheSystemCounterpart() {
        let settings = Self.settings(integrated: false)
        let sources = Self.without(InputSourceInfo.abc.id, InputSourceInfo.korean2Set.id)
        #expect(InputMethodIntegration.sourceID(InputMethodIntegration.hangulID, settings: settings, sources: sources) == InputMethodIntegration.hangulID)
        #expect(InputMethodIntegration.sourceID(InputMethodIntegration.latinID, settings: settings, sources: sources) == InputMethodIntegration.latinID)
        // Each direction depends only on its own counterpart.
        let onlyABC = Self.without(InputSourceInfo.korean2Set.id)
        #expect(InputMethodIntegration.sourceID(InputMethodIntegration.hangulID, settings: settings, sources: onlyABC) == InputMethodIntegration.hangulID)
        #expect(InputMethodIntegration.sourceID(InputMethodIntegration.latinID, settings: settings, sources: onlyABC) == InputSourceInfo.abc.id)
    }

    @Test(arguments: [korean3Set.id, InputSourceInfo.us.id, InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func explicitNonPairDefaultsAreNotTranslatedWhileIntegrated(_ saved: String) {
        let settings = Self.settings(integrated: true, defaultID: saved)
        #expect(InputMethodIntegration.effectiveSettings(settings, sources: Self.all).defaultSourceID == saved)
        #expect(InputMethodIntegration.defaultSource(settings: settings, sources: Self.all)?.id == saved)
    }

    /// With one mode missing the saved default is used as is, even if the remaining mode would match it.
    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func defaultsAreNotTranslatedWithOnlyOneMode(_ removed: String) {
        let sources = Self.without(removed)
        for saved in [nil, InputSourceInfo.abc.id, InputSourceInfo.korean2Set.id] {
            let settings = Self.settings(integrated: true, defaultID: saved)
            #expect(InputMethodIntegration.effectiveSettings(settings, sources: sources) == settings)
            #expect(InputMethodIntegration.defaultSource(settings: settings, sources: sources)?.id == saved ?? InputSourceInfo.abc.id)
        }
    }

    @Test func translatedDefaultsAndAutomaticSourceLeaveTheSavedPreference() {
        for (saved, mapped) in [(Optional<String>.none, InputMethodIntegration.latinID),
                                (InputSourceInfo.abc.id, InputMethodIntegration.latinID),
                                (InputSourceInfo.korean2Set.id, InputMethodIntegration.hangulID)] {
            let settings = Self.settings(integrated: true, defaultID: saved)
            #expect(InputMethodIntegration.defaultSource(settings: settings, sources: Self.all)?.id == mapped)
            #expect(InputMethodIntegration.automaticSource(settings: settings, sources: Self.all)?.id == InputMethodIntegration.latinID)
            #expect(settings.defaultSourceID == saved)
        }
    }
}

@Suite("Default source availability with the KeyHue pair")
struct InputMethodDefaultAvailabilityTests {
    private let pair: [InputSourceInfo] = [.keyHueHangul, .keyHueLatin]

    // A default that is read as the matching KeyHue mode is in use, not missing.
    @Test(arguments: [Optional<String>.none, InputMethodIntegration.abcID, InputMethodIntegration.systemHangulID])
    func translatedDefaultIsNotReportedUnavailableWhileIntegrated(_ saved: String?) {
        var settings = KeyHueSettings()
        settings.integrateInputMethod = true
        settings.defaultSourceID = saved
        #expect(!InputMethodIntegration.isDefaultUnavailable(settings: settings, sources: pair + [.hiragana]))
    }

    @Test func keyHueDefaultReadAsSystemSourceIsNotReportedUnavailable() {
        var settings = KeyHueSettings()
        settings.defaultSourceID = InputMethodIntegration.latinID
        #expect(!InputMethodIntegration.isDefaultUnavailable(settings: settings, sources: [.abc, .korean2Set]))
    }

    @Test func genuinelyMissingDefaultsAreReported() {
        var settings = KeyHueSettings()
        settings.defaultSourceID = InputSourceInfo.german.id
        #expect(InputMethodIntegration.isDefaultUnavailable(settings: settings, sources: [.abc]))
        settings.defaultSourceID = InputMethodIntegration.abcID
        #expect(InputMethodIntegration.isDefaultUnavailable(settings: settings, sources: [.korean2Set] + pair))
        settings.integrateInputMethod = true
        #expect(InputMethodIntegration.isDefaultUnavailable(settings: settings, sources: [.korean2Set, .keyHueHangul]))
        settings.defaultSourceID = nil
        #expect(!InputMethodIntegration.isDefaultUnavailable(settings: settings, sources: []))
    }
}
