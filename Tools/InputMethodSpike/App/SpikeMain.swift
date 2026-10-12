import AppKit
import InputMethodKit
import KeyHueCore

@main
enum SpikeMain {
    @MainActor static func main() {
        let bundle = Bundle.main
        let componentModes = bundle.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [String: Any]
        let modes = componentModes?["tsInputModeListKey"] as? [String: Any]
        guard bundle.bundleIdentifier == InputMethodIntegration.bundleID,
              Set(modes?.keys.map { $0 } ?? []) == InputMethodIntegration.modeIDs,
              bundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String == InputMethodIntegration.connectionName,
              bundle.object(forInfoDictionaryKey: "InputMethodServerControllerClass") as? String == InputMethodIntegration.controllerClassName,
              NSClassFromString(InputMethodIntegration.controllerClassName) == SpikeInputController.self,
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
        guard let server = IMKServer(name: InputMethodIntegration.connectionName, bundleIdentifier: InputMethodIntegration.bundleID) else {
            SpikeLog.error("server initialization failed")
            SpikeLog.file?.flush()
            fputs("error: IMK server initialization failed\n", stderr)
            exit(1)
        }
        SpikeLog.notice("server initialized connection=\(InputMethodIntegration.connectionName)")
        withExtendedLifetime(server) { app.run() }
        SpikeLog.notice("server stopped")
        SpikeLog.file?.flush()
    }
}
