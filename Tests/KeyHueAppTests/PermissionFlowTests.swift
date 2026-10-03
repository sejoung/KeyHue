import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
private final class FakePermissionGate: PermissionGate {
    var hasInputMonitoring = false
    var hasAccessibility = false
    var continues = true
    var requestShowsDialog = true
    var missingChoice: PermissionPrompter.MissingChoice = .later
    var events: [String] = []
    func explain(_ request: PermissionRequest) -> Bool { events.append("explain(\(request))"); return continues }
    func requestInputMonitoring() -> Bool { events.append("request(inputMonitoring)"); return requestShowsDialog }
    func requestAccessibility() { events.append("request(accessibility)") }
    func openSettings(_ permission: PermissionKind) { events.append("open(\(permission))") }
    func explainMissing(_ permission: PermissionKind, feature: String) -> PermissionPrompter.MissingChoice {
        events.append("missing(\(permission)): \(feature)")
        return missingChoice
    }
    func resetStaleEntry(_ permission: PermissionKind) { events.append("reset(\(permission))") }
}

@MainActor
@Suite("Permission flow")
struct PermissionFlowTests {
    nonisolated private static let requests: [PermissionRequest] = [
        .inputMonitoring(.escape), .inputMonitoring(.wrongLanguage), .inputMonitoring(.inputMethodRouting),
        .accessibility(.textFocus), .accessibility(.windowSwitch), .accessibility(.windowMemory)
    ]

    @Test(arguments: requests)
    func grantedPermissionNeverPrompts(_ request: PermissionRequest) {
        let gate = FakePermissionGate()
        gate.hasInputMonitoring = true
        gate.hasAccessibility = true
        #expect(PermissionFlow(gate: gate).allowEnabling(request))
        #expect(gate.events.isEmpty)
    }

    @Test(arguments: requests)
    func cancellingTheExplanationLeavesTheOptionOffAndRequestsNothing(_ request: PermissionRequest) {
        let gate = FakePermissionGate()
        gate.continues = false
        #expect(!PermissionFlow(gate: gate).allowEnabling(request))
        #expect(gate.events == ["explain(\(request))"])
    }

    @Test func inputMonitoringOpensSettingsOnlyWhenTheSystemDialogIsNotShown() {
        let gate = FakePermissionGate()
        #expect(PermissionFlow(gate: gate).allowEnabling(.inputMonitoring(.escape)))
        #expect(gate.events == ["explain(\(PermissionRequest.inputMonitoring(.escape)))", "request(inputMonitoring)"])
        gate.events = []
        gate.requestShowsDialog = false // Already denied once: macOS shows nothing.
        #expect(PermissionFlow(gate: gate).allowEnabling(.inputMonitoring(.wrongLanguage)))
        #expect(gate.events.suffix(2) == ["request(inputMonitoring)", "open(inputMonitoring)"])
    }

    @Test func accessibilityRequestsTrustWithoutOpeningSettings() {
        let gate = FakePermissionGate()
        #expect(PermissionFlow(gate: gate).allowEnabling(.accessibility(.windowMemory)))
        #expect(gate.events.last == "request(accessibility)")
        #expect(!gate.events.contains { $0.hasPrefix("open") })
    }

    @Test func eachPermissionIsCheckedIndependently() {
        let gate = FakePermissionGate()
        gate.hasAccessibility = true
        gate.continues = false
        #expect(PermissionFlow(gate: gate).allowEnabling(.accessibility(.textFocus)))
        #expect(!PermissionFlow(gate: gate).allowEnabling(.inputMonitoring(.escape)))
    }

    @Test(arguments: [PermissionKind.inputMonitoring, .accessibility])
    func requestingAgainResetsTheStaleEntryRequestsAndOpensSettings(_ permission: PermissionKind) {
        let gate = FakePermissionGate()
        gate.requestShowsDialog = false
        PermissionFlow(gate: gate).requestAgain(permission)
        #expect(gate.events == ["reset(\(permission))", "request(\(permission))", "open(\(permission))"])
    }

    @Test func nothingToWarnAboutWhenNoEnabledFeatureLacksPermission() {
        let gate = FakePermissionGate()
        var turnedOff: [PermissionKind] = []
        // Options that need no permission, or are off.
        #expect(PermissionFlow(gate: gate).warnIfMissing(settings: KeyHueSettings(), defaultName: "ABC") { turnedOff.append($0) } == nil)
        var settings = KeyHueSettings()
        settings.resetOnEscape = true
        gate.hasInputMonitoring = true
        #expect(PermissionFlow(gate: gate).warnIfMissing(settings: settings, defaultName: "ABC") { turnedOff.append($0) } == nil)
        #expect(gate.events.isEmpty)
        #expect(turnedOff.isEmpty)
    }

    @Test func missingPermissionChoicesAreHandled() {
        var settings = KeyHueSettings()
        settings.resetOnTextFocusLoss = true
        for choice in [PermissionPrompter.MissingChoice.allowAgain, .turnOff, .later] {
            let gate = FakePermissionGate()
            gate.missingChoice = choice
            var turnedOff: [PermissionKind] = []
            let result = PermissionFlow(gate: gate).warnIfMissing(settings: settings, defaultName: "ABC") { turnedOff.append($0) }
            #expect(result?.0 == .accessibility)
            #expect(result?.1 == choice)
            #expect(turnedOff == (choice == .turnOff ? [.accessibility] : []))
            let followUps = Array(gate.events.dropFirst())
            #expect(followUps == (choice == .allowAgain ? ["reset(accessibility)", "request(accessibility)", "open(accessibility)"] : []))
        }
    }

    @Test func turningOffDisablesEveryFeatureThatNeedsThePermission() {
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update {
            $0.resetOnEscape = true
            $0.warnOnWrongLanguage = true
            $0.resetOnTextFocusLoss = true
        }
        let gate = FakePermissionGate()
        gate.hasAccessibility = true
        gate.missingChoice = .turnOff
        PermissionFlow(gate: gate).warnIfMissing(settings: store.settings, defaultName: "ABC") { permission in
            store.update { PermissionPolicy.disableFeature(needing: permission, in: &$0) }
        }
        #expect(!store.settings.resetOnEscape)
        #expect(!store.settings.warnOnWrongLanguage)
        #expect(store.settings.resetOnTextFocusLoss)
    }

    @Test func inputMonitoringWarningNamesEveryEnabledFeature() {
        var settings = KeyHueSettings()
        settings.resetOnEscape = true
        settings.warnOnWrongLanguage = true
        settings.integrateInputMethod = true
        settings.routeInputMethodPair = true
        let text = PermissionFlow.featureText(for: .inputMonitoring, settings: settings, defaultName: "ABC")
        #expect(text.components(separatedBy: "”, “").count == 3)
        #expect(text.contains("ABC"))
        settings.routeInputMethodPair = false
        settings.warnOnWrongLanguage = false
        #expect(PermissionFlow.featureText(for: .inputMonitoring, settings: settings, defaultName: "ABC").components(separatedBy: "”, “").count == 1)
    }

    @Test func accessibilityWarningNamesTheWindowOptionBeforeTextFocus() {
        var settings = KeyHueSettings()
        settings.resetOnTextFocusLoss = true
        let focus = PermissionFlow.featureText(for: .accessibility, settings: settings, defaultName: "ABC")
        settings.onWindowSwitch = .restoreLast
        let window = PermissionFlow.featureText(for: .accessibility, settings: settings, defaultName: "ABC")
        #expect(focus != window)
        #expect(window.contains(" › "))
        #expect(!focus.contains(" › "))
    }
}
