import Foundation

/// An external TIS selection does not open an input method session in a client
/// that has none yet (ADR 0061). After KeyHue itself selects one of its modes, the
/// server acknowledges the activation or mode callback. Without that within the
/// window, the user's own previous-source shortcut is pressed twice: the client's
/// in-process selection opens the session and the final source is unchanged (ADR 0062).
///
/// One attempt per selection. An app that still does not acknowledge is not
/// repaired again, so a front app without a text input context never flashes the
/// shortcut on every switch. Typing before the window ends cancels the attempt.
@MainActor
public final class InputMethodSessionRepair {
    public enum Outcome: Equatable, Sendable {
        /// The server confirmed the selection; nothing was pressed.
        case acknowledged
        /// Pressed, then the server confirmed the selection.
        case repaired
        /// Pressed, still no confirmation. The app is not repaired again.
        case unrepaired
        /// Not pressed: shortcut or permission unavailable, or the front app changed.
        case skipped
    }

    public static let acknowledgementTimeout: TimeInterval = 0.25
    public static let pressInterval: TimeInterval = 0.05

    private struct Pending {
        let target: String
        let context: AnyHashable
        var acknowledged = false
    }

    private let scheduler: Scheduling
    private let canRepair: () -> Bool
    private let currentContext: () -> AnyHashable?
    private let pressShortcut: () -> Bool
    private var pending: Pending?
    private var generation = 0
    private var unrepairedContexts: Set<AnyHashable> = []
    /// Source notifications during a repair report the intermediate source; ignore them.
    public private(set) var isRepairing = false
    public var onRepairStarted: (() -> Void)?
    public var onFinished: ((Outcome) -> Void)?

    public init(scheduler: Scheduling, canRepair: @escaping () -> Bool,
                currentContext: @escaping () -> AnyHashable?, pressShortcut: @escaping () -> Bool) {
        self.scheduler = scheduler
        self.canRepair = canRepair
        self.currentContext = currentContext
        self.pressShortcut = pressShortcut
    }

    /// Invoke after KeyHue's own successful selection, with the source current before it.
    public func selected(sourceID: String, previousID: String?) {
        guard !isRepairing else { return }
        guard sourceID == InputMethodIntegration.hangulID || sourceID == InputMethodIntegration.latinID,
              previousID != sourceID, let context = currentContext(),
              !unrepairedContexts.contains(context) else {
            cancel()
            return
        }
        generation += 1
        pending = Pending(target: sourceID, context: context)
        let request = generation
        scheduler.schedule(after: Self.acknowledgementTimeout) { [weak self] in
            self?.windowEnded(request)
        }
    }

    /// The server activated a session or received a mode callback for `modeID`.
    public func acknowledged(modeID: String) {
        guard var current = pending, current.target == modeID else { return }
        if isRepairing {
            current.acknowledged = true
            pending = current
            return
        }
        cancel()
        onFinished?(.acknowledged)
    }

    /// A key or click by the user. Pressing a shortcut then could interleave with typing.
    public func interaction() {
        guard !isRepairing else { return }
        cancel()
    }

    private func cancel() {
        generation += 1
        pending = nil
    }

    private func windowEnded(_ request: Int) {
        guard request == generation, let current = pending else { return }
        guard currentContext() == current.context, canRepair() else {
            cancel()
            onFinished?(.skipped)
            return
        }
        isRepairing = true
        onRepairStarted?()
        guard pressShortcut() else { return finish(.skipped) }
        scheduler.schedule(after: Self.pressInterval) { [weak self] in
            guard let self, request == self.generation else { return }
            // Always return to the target, even if the first press was the last useful one.
            _ = self.pressShortcut()
            self.scheduler.schedule(after: Self.acknowledgementTimeout) { [weak self] in
                guard let self, request == self.generation, let current = self.pending else { return }
                if current.acknowledged {
                    self.finish(.repaired)
                } else {
                    self.unrepairedContexts.insert(current.context)
                    self.finish(.unrepaired)
                }
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        isRepairing = false
        cancel()
        onFinished?(outcome)
    }
}
