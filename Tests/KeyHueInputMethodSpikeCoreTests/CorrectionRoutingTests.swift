import Foundation
import KeyHueCore
import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0064·0065: which clients the input method corrects, and in which mode.
/// A client that is not routed is never queried for correction at all.
@Suite("Correction routing")
struct CorrectionRoutingTests {
    private func mode(_ client: String?, settings: CorrectionMode = .manual, excluded: Set<String> = [],
                      override: CorrectionMode? = nil) -> CorrectionMode? {
        CorrectionRouting.mode(clientID: client, settingsMode: settings, excludedApps: excluded, testOverride: override)
    }

    /// Test clients keep fixed modes so tests never depend on the user's setting.
    @Test(arguments: [CorrectionMode.off, .manual, .automatic])
    func testClientsHaveFixedModes(_ settings: CorrectionMode) {
        #expect(mode(CorrectionRouting.manualTestClient, settings: settings) == .manual)
        #expect(mode(CorrectionRouting.automaticTestClient, settings: settings) == .automatic)
    }

    /// ADR 0065: every app the user did not exclude follows the setting.
    @Test(arguments: ["com.apple.TextEdit", "com.apple.Notes", "com.google.Chrome", "com.example.Unknown"])
    func everyAppFollowsTheUserSetting(_ client: String) {
        #expect(mode(client, settings: .manual) == .manual)
        #expect(mode(client, settings: .automatic) == .automatic)
    }

    @Test func offRoutesNothing() {
        #expect(mode("com.apple.TextEdit", settings: .off) == nil)
    }

    @Test func missingClientIsNotRouted() {
        #expect(mode(nil) == nil)
        #expect(mode("") == nil)
    }

    @Test func theUsersExclusionWins() {
        #expect(mode("com.apple.TextEdit", excluded: ["com.apple.TextEdit"]) == nil)
        #expect(mode("com.apple.TextEdit", excluded: ["com.apple.TextEdit"], override: .automatic) == nil)
    }

    /// The opt-in host test sets a short-lived override instead of the user's setting.
    @Test func aTestOverrideReplacesTheSetting() {
        #expect(mode("com.apple.TextEdit", settings: .off, override: .automatic) == .automatic)
        #expect(mode("com.apple.TextEdit", settings: .automatic, override: .manual) == .manual)
        #expect(mode("com.apple.TextEdit", settings: .manual, override: .off) == nil)
    }

    // MARK: test override value

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aValidOverrideNamesAModeAndAnExpiry() {
        #expect(CorrectionRouting.testOverride(from: "automatic@1000600", now: now) == .automatic)
        #expect(CorrectionRouting.testOverride(from: "manual@1000001", now: now) == .manual)
    }

    /// A runner that crashed must not leave the override in effect.
    @Test(arguments: ["automatic@1000000", "automatic@999999", "automatic@1000901", "automatic", "automatic@x",
                      "sometimes@1000600", "@1000600", ""])
    func expiredLongOrMalformedOverridesAreIgnored(_ raw: String) {
        #expect(CorrectionRouting.testOverride(from: raw, now: now) == nil)
    }

    @Test func nonTextOverridesAreIgnored() {
        #expect(CorrectionRouting.testOverride(from: nil, now: now) == nil)
        #expect(CorrectionRouting.testOverride(from: 3, now: now) == nil)
    }
}
