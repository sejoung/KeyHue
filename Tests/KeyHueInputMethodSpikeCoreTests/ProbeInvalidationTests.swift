import Testing
@testable import KeyHueInputMethodSpikeCore

@Suite("Probe invalidation")
struct ProbeInvalidationTests {
    /// Callbacks a mode selection sends keep a pending edit; real input does not.
    @Test func onlySelectionCallbacksSpareAPendingEdit() {
        let spared: [ProbeInvalidation] = [.activation, .commitCallback, .cancelCallback, .modeCallback]
        let dropping: [ProbeInvalidation] = [.mouse, .clientReconciliation, .shortcut, .lostContext, .otherKey]
        #expect(spared.allSatisfy { $0.sparesPendingEdit })
        #expect(!dropping.contains { $0.sparesPendingEdit })
    }

    @Test func eachReasonTellsThePolicyWhatHappened() {
        #expect(ProbeInvalidation.mouse.interruption == .mouse)
        #expect(ProbeInvalidation.activation.interruption == .contextChanged)
        #expect(ProbeInvalidation.clientReconciliation.interruption == .externalEdit)
        #expect(ProbeInvalidation.modeCallback.interruption == .otherKey)
    }
}

@Suite("Front client")
struct FrontClientTests {
    /// Two unknown apps are not the same app.
    @Test func aClientWithoutAnIDIsNeverInFront() {
        #expect(FrontClient.matches(clientID: "com.apple.TextEdit", frontID: "com.apple.TextEdit"))
        #expect(!FrontClient.matches(clientID: "com.apple.TextEdit", frontID: "com.apple.Terminal"))
        #expect(!FrontClient.matches(clientID: nil, frontID: nil))
        #expect(!FrontClient.matches(clientID: "", frontID: ""))
    }
}
