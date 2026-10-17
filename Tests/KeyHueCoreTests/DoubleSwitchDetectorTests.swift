import Foundation
import Testing
@testable import KeyHueCore

/// macOS can switch twice for one ⌘Space; the press's choice is selected again (ADR 0091).
struct DoubleSwitchDetectorTests {
    private let abc = "com.apple.keylayout.ABC"
    private let latin = InputMethodIntegration.latinID
    private let hangul = InputMethodIntegration.hangulID

    private func detector(current: String) -> DoubleSwitchDetector {
        var detector = DoubleSwitchDetector()
        detector.reset(current: current)
        return detector
    }

    /// 2026-10-17 09:08:38 Chrome: ⌘ down .686, up .928, Korean .948, English .971.
    @Test func theChromeSequenceRestoresKorean() {
        var detector = detector(current: latin)
        detector.modifierChanged(at: 38.686)
        detector.modifierChanged(at: 38.928)
        #expect(detector.selected(sourceID: hangul, at: 38.948) == nil)
        #expect(detector.selected(sourceID: latin, at: 38.971) == hangul)
        // The restored selection's own notification is not another reversal.
        #expect(detector.selected(sourceID: hangul, at: 38.990) == nil)
    }

    /// 09:09:03 Chrome, the other direction: English .878, Korean .901.
    @Test func theOtherDirectionRestoresEnglish() {
        var detector = detector(current: hangul)
        detector.modifierChanged(at: 3.857)
        #expect(detector.selected(sourceID: latin, at: 3.878) == nil)
        #expect(detector.selected(sourceID: hangul, at: 3.901) == latin)
    }

    /// 09:24:02 Ghostty after the first fix (which waited for Caps Lock): ⌘ up .609, Korean .632, English .666.
    @Test func theGhosttySequenceRestoresKorean() {
        var detector = detector(current: latin)
        detector.modifierChanged(at: 2.290)
        detector.modifierChanged(at: 2.609)
        #expect(detector.selected(sourceID: hangul, at: 2.632) == nil)
        #expect(detector.selected(sourceID: latin, at: 2.666) == hangul)
    }

    /// 09:09:05–07: one switch per press is ordinary use.
    @Test func singleSwitchesAreLeftAlone() {
        var detector = detector(current: hangul)
        let presses: [(TimeInterval, String)] = [(5.260, latin), (6.092, hangul), (6.978, latin), (7.716, hangul)]
        for (time, id) in presses {
            detector.modifierChanged(at: time - 0.02)
            #expect(detector.selected(sourceID: id, at: time) == nil)
        }
    }

    @Test func aReversalWithoutAModifierIsNotTheSystems() {
        var detector = detector(current: latin)
        #expect(detector.selected(sourceID: hangul, at: 1.0) == nil)
        #expect(detector.selected(sourceID: latin, at: 1.02) == nil)
    }

    @Test func aSlowReversalIsAnotherPress() {
        var detector = detector(current: latin)
        detector.modifierChanged(at: 0.98)
        #expect(detector.selected(sourceID: hangul, at: 1.0) == nil)
        detector.modifierChanged(at: 1.05)
        #expect(detector.selected(sourceID: latin, at: 1.0 + DoubleSwitchDetector.reversal + 0.01) == nil)
    }

    @Test func anOldModifierChangeDoesNotCount() {
        var detector = detector(current: latin)
        detector.modifierChanged(at: 0)
        #expect(detector.selected(sourceID: hangul, at: 1.0) == nil)
        #expect(detector.selected(sourceID: latin, at: 1.02) == nil)
    }

    /// A key, a click or KeyHue's own selection (a route, a session repair) in between.
    @Test func anInterruptionMakesTheChangeSomeonesChoice() {
        var detector = detector(current: latin)
        detector.modifierChanged(at: 0.98)
        #expect(detector.selected(sourceID: hangul, at: 1.0) == nil)
        detector.interrupt()
        #expect(detector.selected(sourceID: latin, at: 1.02) == nil)
    }

    /// KeyHue's own selection also clears the press: its later notifications are not reversals.
    @Test func ownSelectionsAfterThePressAreNotRestored() {
        var detector = detector(current: hangul)
        detector.modifierChanged(at: 0.98)
        #expect(detector.selected(sourceID: abc, at: 1.0) == nil)
        detector.interrupt() // a route selects Korean, then English
        #expect(detector.selected(sourceID: hangul, at: 1.01) == nil)
        #expect(detector.selected(sourceID: latin, at: 1.02) == nil)
        #expect(detector.selected(sourceID: hangul, at: 1.03) == nil)
    }

    @Test func detoursAreNotRestored() {
        var detector = detector(current: latin)
        detector.modifierChanged(at: 0.98)
        #expect(detector.selected(sourceID: abc, at: 1.0) == nil)
        #expect(detector.selected(sourceID: latin, at: 1.02) == nil)
    }

    @Test func aBaselineResetForgetsTheFirstChange() {
        var detector = detector(current: latin)
        detector.modifierChanged(at: 0.98)
        #expect(detector.selected(sourceID: hangul, at: 1.0) == nil)
        detector.reset(current: hangul)
        #expect(detector.selected(sourceID: latin, at: 1.02) == nil)
    }

    @Test func repeatedNotificationsOfOneSourceAreIgnored() {
        var detector = detector(current: latin)
        detector.modifierChanged(at: 0.98)
        #expect(detector.selected(sourceID: hangul, at: 1.0) == nil)
        #expect(detector.selected(sourceID: hangul, at: 1.01) == nil)
        #expect(detector.selected(sourceID: latin, at: 1.02) == hangul)
    }
}
