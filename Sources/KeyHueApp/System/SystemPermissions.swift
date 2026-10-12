import AppKit
import KeyHueCore

/// macOS privacy permissions as this process sees them. The monitors that need one
/// and the permission flow ask here; nothing else calls the system for them.
@MainActor
enum SystemPermissions {
    /// macOS keeps the first answer per process: a permission allowed since launch is
    /// seen by a new process (`PermissionGate.isGrantedInNewProcess`, ADR 0084).
    static func has(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    /// The system's request, which also lists KeyHue in System Settings. false when
    /// macOS shows nothing because the permission was decided before.
    @discardableResult
    static func request(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .inputMonitoring:
            return CGRequestListenEventAccess()
        case .accessibility:
            // The prompt option always shows the system's guide while not trusted.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return true
        }
    }
}
