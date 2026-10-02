import Testing
@testable import KeyHueApp

@MainActor
@Suite("Input method activation catalog")
struct InputMethodActivationTests {
    private struct Source {
        var id: String
        var enabled: Bool
        var generation: Int
    }

    @Test func disabledNonSelectableParentIsNotReadyEvenWhenBothModesReportEnabled() throws {
        let sources = ["parent", "hangul", "latin"].map { Source(id: $0, enabled: $0 != "parent", generation: 0) }
        let ready = try InputMethodActivation.enable(ids: ["parent", "hangul", "latin"],
            sources: { sources }, id: { $0.id }, isEnabled: { $0.enabled }, activate: { _ in })
        #expect(!ready)
    }

    @Test func parentActivationCanRevealModesAndEachActivationUsesFreshHandles() throws {
        var enabled: Set<String> = []
        var generation = 0
        var requests: [String] = []
        let ready = try InputMethodActivation.enable(
            ids: ["parent", "hangul", "latin"],
            sources: {
                generation += 1
                let ids = enabled.contains("parent") ? ["parent", "hangul", "latin"] : ["parent"]
                return ids.map { Source(id: $0, enabled: enabled.contains($0), generation: generation) }
            },
            id: { $0.id }, isEnabled: { $0.enabled },
            activate: {
                #expect($0.generation == generation)
                requests.append($0.id)
                enabled.insert($0.id)
            })
        #expect(ready)
        #expect(requests == ["parent", "hangul", "latin"])
    }

    @Test func successfulAPIWithoutEnabledPropertyRemainsPending() throws {
        let sources = ["parent", "hangul", "latin"].map { Source(id: $0, enabled: $0 != "hangul", generation: 0) }
        var requests: [String] = []
        let ready = try InputMethodActivation.enable(ids: ["parent", "hangul", "latin"],
                                                     sources: { sources }, id: { $0.id },
                                                     isEnabled: { $0.enabled }, activate: { requests.append($0.id) })
        #expect(!ready)
        #expect(requests == ["hangul"])
    }

    @Test func missingModeKeepsParentActivationAndReturnsPending() throws {
        var parentEnabled = false
        let ready = try InputMethodActivation.enable(ids: ["parent", "hangul", "latin"],
            sources: { [Source(id: "parent", enabled: parentEnabled, generation: 0)] },
            id: { $0.id }, isEnabled: { $0.enabled }, activate: { _ in parentEnabled = true })
        #expect(!ready)
        #expect(parentEnabled)
    }
}
