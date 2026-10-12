import Foundation
import InputMethodKit
import KeyHueInputMethodSpikeCore

/// ADR 0066: for clients that drop text committed with Tab or a navigation key,
/// the composition is committed after the key that ended it. ADR 0068: there the
/// consumed correction shortcut needs a placeholder mark instead.
final class DetachedCommitDelivery {
    private var held = HeldCommit()
    private var heldClient: (any IMKTextInput)?
    private let apply: ([ProbeSession.Action], any IMKTextInput) -> Void

    /// - Parameter apply: delivers actions to a client through the session.
    init(apply: @escaping ([ProbeSession.Action], any IMKTextInput) -> Void) {
        self.apply = apply
    }

    /// Delivers the held commit before anything else reaches the client.
    func deliver() {
        guard !held.isEmpty else { return }
        let actions = held.take()
        if let client = heldClient { apply(actions, client) }
        heldClient = nil
    }

    /// A key faster than the held commit's delivery. true: the key is consumed.
    func beforeKey(detached: Bool, client: any IMKTextInput) -> Bool {
        let result = held.beforeKey(detached: detached)
        if result.consumeKey { return true }
        if !result.deliver.isEmpty {
            apply(result.deliver, heldClient ?? client)
            heldClient = nil
        }
        return false
    }

    /// The key is consumed; `actions` follow once it has finished in the client.
    func hold(_ actions: [ProbeSession.Action], client: any IMKTextInput) {
        held.hold(actions)
        heldClient = client
        // Same main-queue work item pattern as the correction probes.
        DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
            guard let self, Thread.isMainThread else { return }
            self.deliver()
        })
    }

    /// Delivers the composition the consumed shortcut committed, or the placeholder
    /// these clients need to keep the key from the program.
    func commitForShortcut(clientID: String?, committed: [ProbeSession.Action], client: any IMKTextInput) {
        let consumed = DetachedCommit.consume(clientID: clientID, committed: committed)
        apply(consumed.now, client)
        guard !consumed.after.isEmpty else { return }
        // Same main-queue work item pattern as the held commit.
        DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
            guard let self, Thread.isMainThread else { return }
            self.apply(consumed.after, client)
        })
    }
}
