import Foundation

/// Input source switches in quick succession: the user pressing the switch again
/// because the last press did not seem to work (2026-10-07 17:41: four presses in
/// five seconds after an unlock, the color seemingly unchanged). Changes within
/// `settle` of each other are one switch, as a route makes three in 20 ms. A burst
/// is reported once, with its changes, so the log marks the moment to look at.
public struct SwitchBurstDetector: Sendable {
    public struct Change: Equatable, Sendable {
        public let time: TimeInterval
        public let sourceID: String

        public init(time: TimeInterval, sourceID: String) {
            self.time = time
            self.sourceID = sourceID
        }
    }

    public static let window: TimeInterval = 3
    public static let settle: TimeInterval = 0.1
    public static let switches = 3

    private var changes: [Change] = []
    private var reported = false

    public init() {}

    /// - Parameter time: a monotonic clock, in seconds.
    /// - Returns: the burst's changes, the first time it reaches `switches` within `window`.
    public mutating func record(sourceID: String, at time: TimeInterval) -> [Change]? {
        if let last = changes.last, time - last.time > Self.window { reported = false }
        changes.append(Change(time: time, sourceID: sourceID))
        changes.removeAll { time - $0.time > Self.window }
        var count = 0
        var lastSwitch = -Double.infinity
        for change in changes where change.time - lastSwitch > Self.settle {
            count += 1
            lastSwitch = change.time
        }
        guard count >= Self.switches, !reported else { return nil }
        reported = true
        return changes
    }
}
