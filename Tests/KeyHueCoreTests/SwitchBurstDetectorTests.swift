import Foundation
import Testing
@testable import KeyHueCore

/// Switches in quick succession are logged as a suspect moment: the user pressed the
/// switch again because the last press did not seem to work.
struct SwitchBurstDetectorTests {
    private let abc = "com.apple.keylayout.ABC"
    private let latin = InputMethodIntegration.latinID
    private let hangul = InputMethodIntegration.hangulID

    /// 2026-10-07 17:41 after an unlock, KakaoTalk: a route, then three presses.
    @Test func theUnlockSequenceIsReportedOnce() {
        var detector = SwitchBurstDetector()
        let sequence: [(TimeInterval, String)] = [
            (28.770, abc), (28.777, latin), (28.791, hangul), // one press, routed
            (32.415, latin),
            (32.774, abc), (32.777, latin), (32.781, hangul),
        ]
        for (time, id) in sequence {
            #expect(detector.record(sourceID: id, at: time) == nil)
        }
        let burst = detector.record(sourceID: latin, at: 33.971)
        #expect(burst?.first == .init(time: 32.415, sourceID: latin))
        #expect(burst?.last == .init(time: 33.971, sourceID: latin))
        #expect(burst?.count == 5)
        #expect(detector.record(sourceID: hangul, at: 34.5) == nil) // the same burst
    }

    /// A route alone is one switch, and switches seconds apart are ordinary use.
    @Test func routesAndOrdinaryTogglesAreNotReported() {
        var detector = SwitchBurstDetector()
        #expect(detector.record(sourceID: abc, at: 0) == nil)
        #expect(detector.record(sourceID: latin, at: 0.007) == nil)
        #expect(detector.record(sourceID: hangul, at: 0.02) == nil)
        for (index, time) in [4.0, 8.0, 12.0, 16.0].enumerated() {
            #expect(detector.record(sourceID: index.isMultiple(of: 2) ? latin : hangul, at: time) == nil)
        }
    }

    @Test func aLaterBurstIsReportedAgain() {
        var detector = SwitchBurstDetector()
        _ = detector.record(sourceID: latin, at: 0)
        _ = detector.record(sourceID: hangul, at: 0.5)
        #expect(detector.record(sourceID: latin, at: 1) != nil)
        _ = detector.record(sourceID: hangul, at: 10)
        _ = detector.record(sourceID: latin, at: 10.5)
        #expect(detector.record(sourceID: hangul, at: 11) != nil)
    }
}
