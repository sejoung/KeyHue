import Foundation
import KeyHueCore

/// Which clients the input method corrects, and in which mode (ADR 0064, 0065):
/// every app the user did not exclude. A client that is not routed never enters
/// the correction path: no word tracking, no client queries, no logs.
public enum CorrectionRouting {
    public static let manualTestClient = "io.github.sejoung.keyhue.testclient.manual-probe"
    public static let automaticTestClient = "io.github.sejoung.keyhue.testclient.correction-probe"
    /// The input method's own preference key for the opt-in host test only.
    public static let testOverrideKey = "correctionModeTestOverride"
    /// An override lives at most this long, so a crashed runner cannot leave it on.
    public static let testOverrideLifetime: TimeInterval = 15 * 60

    public static func mode(clientID: String?, settingsMode: CorrectionMode, excludedApps: Set<String>,
                            testOverride: CorrectionMode?) -> CorrectionMode? {
        guard let clientID, !clientID.isEmpty else { return nil }
        // Test clients keep fixed modes so tests never depend on the user's setting.
        if clientID == manualTestClient { return .manual }
        if clientID == automaticTestClient { return .automatic }
        guard !excludedApps.contains(clientID) else { return nil }
        let mode = testOverride ?? settingsMode
        return mode == .off ? nil : mode
    }

    /// `"<mode>@<unix expiry>"`, valid only before its expiry and for at most
    /// `testOverrideLifetime` from now.
    public static func testOverride(from raw: Any?, now: Date) -> CorrectionMode? {
        guard let text = raw as? String else { return nil }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let mode = CorrectionMode(rawValue: String(parts[0])),
              let expiry = TimeInterval(parts[1]) else { return nil }
        let remaining = expiry - now.timeIntervalSince1970
        guard remaining > 0, remaining <= testOverrideLifetime else { return nil }
        return mode
    }
}
