import Foundation
import Testing
@testable import KeyHueCore

/// 앱별·창별 기억이 함께 쓰는 LRU(`RecentlyUsedMap`).
@Suite("Recently used map")
struct RecentlyUsedMapTests {
    @Test func reportsWhatChanged() {
        var map = RecentlyUsedMap<String, String>(capacity: 2)
        let first = map.set("abc", for: "a")
        #expect(first.valueChanged && first.moved && !first.evicted)
        map.set("abc", for: "b")
        let movedOnly = map.set("abc", for: "a")
        #expect(!movedOnly.valueChanged && movedOnly.moved)
        let changedOnly = map.set("ko", for: "a")
        #expect(changedOnly.valueChanged && !changedOnly.moved)
        let nothing = map.set("ko", for: "a")
        #expect(!nothing.valueChanged && !nothing.moved && !nothing.evicted)
        #expect(map.order == ["b", "a"])
    }

    @Test func evictsTheLeastRecentlyUsedBeyondCapacity() {
        var map = RecentlyUsedMap(capacity: 2, values: ["old": "s", "mid": "s"], order: ["old", "mid"])
        let change = map.set("s", for: "new")
        #expect(change.evicted)
        #expect(map.values == ["mid": "s", "new": "s"])
        #expect(map.order == ["mid", "new"])
        map.removeAll()
        #expect(map.values.isEmpty && map.order.isEmpty)
    }
}

/// 한 번에 하나만 기다리는 예약(`PendingSlot`): 앱·창 전환 대기와 전환 뒤 확인.
@Suite("Pending slot")
struct PendingSlotTests {
    @Test func onlyTheLatestStartFinishesOnce() {
        var slot = PendingSlot<String>()
        let first = slot.start("a")
        let second = slot.start("b")
        #expect(slot.isPending && slot.value == "b")
        let supersededFinished = slot.finish(first)
        let latestFinished = slot.finish(second)
        #expect(!supersededFinished && latestFinished)
        #expect(!slot.isPending && slot.value == nil)
        let finishedTwice = slot.finish(second)
        #expect(!finishedTwice)
    }

    @Test func cancelledStartNeverFinishes() {
        var slot = PendingSlot<Void>()
        let token = slot.start()
        slot.cancel()
        let finished = slot.finish(token)
        #expect(!slot.isPending && !finished)
    }
}

/// 앱별 기억은 프로토콜(`AppInputRemembering`)로 받는다: UserDefaults 없이도 자동 전환이 동작한다.
@MainActor
private final class InMemoryAppInputs: AppInputRemembering {
    var entries: [String: String] = [:]
    private(set) var clears = 0
    func record(sourceID: String, for bundleID: String) { entries[bundleID] = sourceID }
    func clear() { entries = [:]; clears += 1 }
}

@MainActor
@Suite("AutoResetCoordinator with any app memory")
struct AutoResetAppMemoryProtocolTests {
    @Test func recordsRestoresAndForgetsThroughTheProtocol() {
        var settings = KeyHueSettings()
        settings.onAppSwitch = .restoreLast
        let memory = InMemoryAppInputs()
        memory.entries["target"] = InputSourceInfo.korean2Set.id
        let switcher = FakeSwitcher(current: .abc)
        let scheduler = FakeScheduler()
        let coordinator = AutoResetCoordinator(switcher: switcher, scheduler: scheduler, memory: memory) { settings }

        coordinator.appActivated(previousBundleID: "previous", currentBundleID: "target", sourceBeforeActivation: .abc)
        scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(memory.entries["previous"] == InputSourceInfo.abc.id)
        #expect(switcher.currentSource == .korean2Set)

        coordinator.forgetRememberedInputs()
        #expect(memory.clears == 1 && memory.entries.isEmpty)
        scheduler.advance(by: 10)
    }
}
