import Foundation
import KeyHueCore

/// Observes the input method server's session acknowledgement (ADR 0062).
/// The notification carries only a mode ID. Delivered immediately because KeyHue
/// is almost always inactive (ADR 0023).
@MainActor
final class InputMethodAcknowledgementMonitor: NSObject {
    private var onAcknowledgement: ((String) -> Void)?

    func start(_ onAcknowledgement: @escaping (String) -> Void) {
        self.onAcknowledgement = onAcknowledgement
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(acknowledged(_:)),
            name: Notification.Name(InputMethodIntegration.sessionAcknowledgement),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func acknowledged(_ notification: Notification) {
        guard let modeID = notification.object as? String else { return }
        MainActor.assumeIsolated { onAcknowledgement?(modeID) }
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
