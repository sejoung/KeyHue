import AppKit
import Testing

/// `swift test` has no app entry point. Initialize the display connection before
/// AppKit/Carbon tests use it, including when a single test is selected on CI.
struct AppKitTestSupport: SuiteTrait, TestTrait {
    var isRecursive: Bool { true }

    func prepare(for test: Test) async throws {
        await MainActor.run {
            _ = NSApplication.shared
        }
    }
}

extension Trait where Self == AppKitTestSupport {
    static var appKit: Self { Self() }
}
