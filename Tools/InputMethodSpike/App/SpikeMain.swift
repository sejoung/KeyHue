import AppKit
import InputMethodKit

enum SpikeMetadata {
    static let bundleID = "io.github.sejoung.keyhue.inputmethod.spike"
    static let hangulID = bundleID + ".Hangul"
    static let latinID = bundleID + ".Latin"
    static let connection = "KeyHueInputMethodSpike_Connection"
}

@main
enum SpikeMain {
    @MainActor static func main() {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == SpikeMetadata.bundleID,
              bundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String == SpikeMetadata.connection,
              bundle.object(forInfoDictionaryKey: "InputMethodServerControllerClass") as? String == "KeyHueSpikeInputController",
              NSClassFromString("KeyHueSpikeInputController") == SpikeInputController.self,
              SpikeInputController.instancesRespond(to: #selector(SpikeInputController.handle(_:client:))),
              SpikeInputController.instancesRespond(to: #selector(SpikeInputController.commitComposition(_:))) else {
            fputs("error: run the IMK service included in KeyHue.app by scripts/build-app.sh\n", stderr)
            exit(1)
        }
        if CommandLine.arguments.dropFirst() == ["--self-check"] {
            print("IMK spike metadata/controller self-check passed (no server registration or installation)")
            return
        }
        guard CommandLine.arguments.count == 1 else {
            fputs("usage: KeyHueInputMethodSpike [--self-check]\n", stderr)
            exit(64)
        }
        let app = NSApplication.shared
        SpikeLog.notice("server starting version=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") build=\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") path=\(bundle.bundleURL.path)")
        guard let server = IMKServer(name: SpikeMetadata.connection, bundleIdentifier: SpikeMetadata.bundleID) else {
            SpikeLog.error("server initialization failed")
            SpikeLog.file?.flush()
            fputs("error: IMK server initialization failed\n", stderr)
            exit(1)
        }
        SpikeLog.notice("server initialized connection=\(SpikeMetadata.connection)")
        withExtendedLifetime(server) { app.run() }
        SpikeLog.notice("server stopped")
        SpikeLog.file?.flush()
    }
}
