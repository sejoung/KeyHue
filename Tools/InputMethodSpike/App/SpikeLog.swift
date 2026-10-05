import Foundation
import KeyHueCore
import os

/// No key positions, characters or composition text enter these messages.
enum SpikeLog {
    static let logger = Logger(subsystem: "io.github.sejoung.keyhue.inputmethod.spike", category: "session")
    static let file: RotatingLogFile? = Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Input Methods"
        ? RotatingLogFile(url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KeyHue/KeyHueInputMethod.log")) : nil

    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        file?.write("pid=\(ProcessInfo.processInfo.processIdentifier) \(message)", level: "notice", category: "IMK")
    }
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        file?.write("pid=\(ProcessInfo.processInfo.processIdentifier) \(message)", level: "error", category: "IMK")
    }
}
