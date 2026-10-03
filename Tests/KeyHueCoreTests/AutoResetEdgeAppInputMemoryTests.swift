import Foundation
import Testing
@testable import KeyHueCore

/// 앱별 기억 저장소의 엣지 케이스(깨진 값, 이전 버전 값, 개수 제한).
@MainActor
@Suite("AppInputMemory edge cases")
struct AutoResetEdgeAppInputMemoryTests {
    @Test func memoryWithoutSavedOrderIsEvictedFirstInNameOrder() {
        // 순서를 저장하기 전 버전의 기억은 이름순으로 가장 오래된 것으로 본다. 순서가 있는 것은 그 뒤다
        let defaults = makeTestDefaults()
        defaults.set(["zeta": "s", "alpha": "s", "newer": "s"], forKey: "appInputSources")
        defaults.set(["newer"], forKey: "appInputSourcesOrder")
        let memory = AppInputMemory(defaults: defaults)
        for index in 0..<(AppInputMemory.maxEntries - 2) { // 3 + 198 = 201 → 하나 지운다
            memory.record(sourceID: "s", for: "app\(index)")
        }
        #expect(memory.entries.count == AppInputMemory.maxEntries)
        #expect(memory.entries["alpha"] == nil)
        #expect(memory.entries["zeta"] == "s")
        memory.record(sourceID: "s", for: "one.more")
        #expect(memory.entries["zeta"] == nil)
        #expect(memory.entries["newer"] == "s")
    }

    @Test func savedOrderNamesWithoutAMemoryAreIgnored() {
        // 순서에만 남은 이름(값이 깨져 버려진 앱 등)이 개수를 차지해 실제 기억을 지우면 안 된다
        let defaults = makeTestDefaults()
        defaults.set(["kept": "s", "broken": 7], forKey: "appInputSources")
        defaults.set(["kept", "broken", "ghost"], forKey: "appInputSourcesOrder")
        let memory = AppInputMemory(defaults: defaults)
        for index in 0..<(AppInputMemory.maxEntries - 1) {
            memory.record(sourceID: "s", for: "app\(index)")
        }
        #expect(memory.entries.count == AppInputMemory.maxEntries)
        #expect(memory.entries["kept"] == "s")
    }

    @Test(arguments: [false, true])
    func wrongTypesAreTreatedAsEmptyAndRecordingRecovers(corruptOrderOnly: Bool) {
        let defaults = makeTestDefaults()
        if corruptOrderOnly {
            defaults.set(["a": "s"], forKey: "appInputSources")
        } else {
            defaults.set("garbage", forKey: "appInputSources")
        }
        defaults.set(42, forKey: "appInputSourcesOrder")
        let memory = AppInputMemory(defaults: defaults)
        #expect(memory.entries == (corruptOrderOnly ? ["a": "s"] : [:]))

        memory.record(sourceID: "ko", for: "b")
        let reloaded = AppInputMemory(defaults: defaults)
        #expect(reloaded.entries == (corruptOrderOnly ? ["a": "s", "b": "ko"] : ["b": "ko"]))
        #expect(defaults.stringArray(forKey: "appInputSourcesOrder") == (corruptOrderOnly ? ["a", "b"] : ["b"]))
    }

    @Test func changingAnAppsSourceMakesItTheNewest() {
        let defaults = makeTestDefaults()
        let memory = AppInputMemory(defaults: defaults)
        for index in 0..<AppInputMemory.maxEntries {
            memory.record(sourceID: "s", for: "app\(index)")
        }
        memory.record(sourceID: "changed", for: "app0") // 가장 오래된 앱의 Source가 바뀌어 가장 최근이 된다
        AppInputMemory(defaults: defaults).record(sourceID: "s", for: "new") // 다시 실행한 뒤에도 순서가 이어진다
        let reloaded = AppInputMemory(defaults: defaults)
        #expect(reloaded.entries["app0"] == "changed")
        #expect(reloaded.entries["app1"] == nil)
        #expect(reloaded.entries["new"] == "s")
    }

    @Test func clearAlsoForgetsTheOrder() {
        let defaults = makeTestDefaults()
        let memory = AppInputMemory(defaults: defaults)
        memory.record(sourceID: "s", for: "a")
        memory.clear()
        #expect(defaults.object(forKey: "appInputSourcesOrder") == nil)
        memory.record(sourceID: "s", for: "b")
        #expect(defaults.stringArray(forKey: "appInputSourcesOrder") == ["b"])
        #expect(AppInputMemory(defaults: defaults).entries == ["b": "s"])
    }
}
