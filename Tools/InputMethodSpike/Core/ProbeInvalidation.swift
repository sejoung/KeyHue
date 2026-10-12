/// Why the automatic correction adapter drops its work (ADR 0064).
public enum ProbeInvalidation: Sendable {
    case activation, commitCallback, cancelCallback, modeCallback
    case mouse, clientReconciliation, shortcut, lostContext, otherKey

    /// A mode selection may send these callbacks between the two observations of a
    /// pending edit. The next observation verifies the exact client, text, caret and
    /// mode, so they leave a pending edit alone.
    public var sparesPendingEdit: Bool {
        switch self {
        case .activation, .commitCallback, .cancelCallback, .modeCallback: return true
        case .mouse, .clientReconciliation, .shortcut, .lostContext, .otherKey: return false
        }
    }

    /// What the policy is told.
    public var interruption: CorrectionInterruption {
        switch self {
        case .mouse: return .mouse
        case .activation, .commitCallback, .cancelCallback: return .contextChanged
        case .clientReconciliation: return .externalEdit
        case .modeCallback, .shortcut, .lostContext, .otherKey: return .otherKey
        }
    }
}
