import Foundation
import Testing
@testable import KeyHueCore

extension InputSourceInfo {
    static let keyHueHangul = InputSourceInfo(id: InputMethodIntegration.hangulID, localizedName: "KeyHue Korean", languages: ["ko"], isASCIICapable: false)
    static let keyHueLatin = InputSourceInfo(id: InputMethodIntegration.latinID, localizedName: "KeyHue English", languages: ["en"], isASCIICapable: true)
}

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

    @Test func systemKoreanDefaultFallsBackToItselfWhenTheModeDisappearsBeforeExecution() {
        let h = IntegrationHarness()
        h.settings.defaultSourceID = InputSourceInfo.korean2Set.id
        h.settings.resetOnEscape = true
        // ESC resolves the effective default now and selects it on the next turn.
        h.reset.keyDown(keyCode: 53, isAutoRepeat: false, current: .abc)
        h.switcher.known.removeAll { $0.id == InputMethodIntegration.hangulID }
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .korean2Set)
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
        #expect(h.switcher.performed == [.select(sourceID: pair.1.id)])
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
        #expect(h.switcher.performed.count == 1)
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
        #expect(h.switcher.performed.count == 1)
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
