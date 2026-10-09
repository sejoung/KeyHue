import Foundation
import KeyHueCore

/// Short-lived internal modes of the KeyHue executable (ADR 0053). Parsing is pure
/// so argument validation is testable; `KeyHueAppMain` performs the work and exits.
enum WorkerCommand: Equatable {
    case selectInputSource(id: String)
    /// Selects like the app and runs the same input method session repair (ADR 0062).
    case selectInputSourceRepairing(id: String)
    case inputSourceStatus
    case relaunchAfterInputMethod(parentPID: Int32, finishSetup: Bool)
    /// `scripts/uninstall.sh` (ADR 0074): leave and turn off the KeyHue input
    /// sources and remove the login item, which only this app's process can do.
    case prepareUninstall
    /// `scripts/uninstall.sh` asks the app instead of `sfltool dumpbtm`, which wants an
    /// administrator password every time (ADR 0074).
    case loginItemStatus
    /// ADR 0077: a fresh process posts a terminal fix's Backspaces. macOS keeps the
    /// event-posting answer per process, so a running app sees a new grant only after
    /// a restart; a new process sees it at once.
    case postBackspaces(pid: Int32, count: Int)
    /// ADR 0084: whether a fresh process has the permission. This process may still
    /// hold macOS's first answer although the user has allowed it since.
    case permissionStatus(PermissionKind)
    /// ADR 0084: asks for the permission from a fresh process, which adds KeyHue to the
    /// System Settings list again after its entry was reset.
    case requestPermission(PermissionKind)

    static let selectFlag = "--keyhue-select-input-source"
    static let selectRepairingFlag = "--keyhue-select-input-source-repairing"
    static let statusFlag = "--keyhue-input-source-status"
    static let relaunchFlag = "--keyhue-relaunch-after-input-method"
    static let finishSetupFlag = "--keyhue-finish-input-method-setup"
    static let prepareUninstallFlag = "--keyhue-prepare-uninstall"
    static let loginItemStatusFlag = "--keyhue-login-item-status"
    static let postBackspacesFlag = "--keyhue-post-backspaces"
    static let permissionStatusFlag = "--keyhue-permission-status"
    static let requestPermissionFlag = "--keyhue-request-permission"
    /// Passed to the app relaunched after an input method install or removal (ADR 0084).
    static let relaunchedFlag = "--keyhue-relaunched-after-input-method"
    /// Exit status when this process lacks the permission (EX_NOPERM).
    static let noPermission: Int32 = 77
    /// Exit status for malformed worker arguments (EX_USAGE).
    static let usageError: Int32 = 64

    enum Parsed: Equatable {
        /// Not a worker invocation: start the app.
        case app
        case worker(WorkerCommand)
        /// A worker flag with malformed arguments: exit with `usageError`.
        case invalid
    }

    /// - Parameter arguments: command-line arguments without the executable path.
    static func parse(_ arguments: [String]) -> Parsed {
        switch arguments.first {
        case selectFlag:
            // Exact selectable-source lookup in the worker validates the ID itself.
            guard arguments.count == 2, !arguments[1].isEmpty else { return .invalid }
            return .worker(.selectInputSource(id: arguments[1]))
        case selectRepairingFlag:
            guard arguments.count == 2, !arguments[1].isEmpty else { return .invalid }
            return .worker(.selectInputSourceRepairing(id: arguments[1]))
        case statusFlag:
            return arguments.count == 1 ? .worker(.inputSourceStatus) : .invalid
        case prepareUninstallFlag:
            return arguments.count == 1 ? .worker(.prepareUninstall) : .invalid
        case loginItemStatusFlag:
            return arguments.count == 1 ? .worker(.loginItemStatus) : .invalid
        case postBackspacesFlag:
            guard arguments.count == 3, let pid = Int32(arguments[1]), pid > 0, let count = Int(arguments[2]),
                  (1...TerminalKeyPost.maximumBackspaces).contains(count) else { return .invalid }
            return .worker(.postBackspaces(pid: pid, count: count))
        case permissionStatusFlag:
            guard arguments.count == 2, let kind = permission(named: arguments[1]) else { return .invalid }
            return .worker(.permissionStatus(kind))
        case requestPermissionFlag:
            guard arguments.count == 2, let kind = permission(named: arguments[1]) else { return .invalid }
            return .worker(.requestPermission(kind))
        case relaunchFlag:
            guard arguments.count == 3, let pid = Int32(arguments[1]), pid > 0,
                  ["setup", "plain"].contains(arguments[2]) else { return .invalid }
            return .worker(.relaunchAfterInputMethod(parentPID: pid, finishSetup: arguments[2] == "setup"))
        default:
            return .app
        }
    }

    /// The worker argument for a permission: its TCC service name.
    static func permission(named name: String) -> PermissionKind? {
        [PermissionKind.inputMonitoring, .accessibility].first { $0.tccService == name }
    }

    /// Any invocation starting with a worker flag, valid or not, is not the app.
    static func isWorker(_ arguments: [String]) -> Bool {
        parse(arguments) != .app
    }

    /// `open` arguments that start a fresh KeyHue after the old one quits.
    static func relaunchOpenArguments(bundlePath: String, finishSetup: Bool) -> [String] {
        ["-n", bundlePath, "--args", relaunchedFlag] + (finishSetup ? [finishSetupFlag] : [])
    }

    /// Arguments the running app passes to its relaunch helper.
    static func relaunchArguments(parentPID: Int32, finishSetup: Bool) -> [String] {
        [relaunchFlag, String(parentPID), finishSetup ? "setup" : "plain"]
    }
}
