import AppKit
import KeyHueCore
import SwiftUI

/// 매뉴얼·웹사이트용 설정 창 이미지를 실제 SwiftUI 뷰로 렌더링한다.
///
///     KeyHue --render-screenshots <dir>
///
/// 사용자 설정을 건드리지 않도록 임시 UserDefaults와 예시 입력 소스를 쓴다. 화면 기록 권한이 필요 없다.
/// `scripts/screenshots.sh`가 이 모드를 호출한다.
@MainActor
enum DocScreenshots {
    static let flag = "--render-screenshots"

    /// 스크린샷 모드로 실행됐으면 렌더링 후 true.
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag) else { return false }
        guard index + 1 < arguments.count else {
            FileHandle.standardError.write("usage: KeyHue \(flag) <output-dir>\n".data(using: .utf8)!)
            exit(64)
        }
        render(to: URL(fileURLWithPath: arguments[index + 1]))
        return true
    }

    /// 예시 입력 소스(영문 + 한국어 + 일본어). 이름은 macOS가 해당 언어로 보여주는 이름을 따른다.
    static func demoSources(for language: AppLanguage) -> [InputSourceInfo] {
        let names: (korean: String, hiragana: String) = language == .ko ? ("두벌식", "히라가나") : ("2-Set Korean", "Hiragana")
        return [
            InputSourceInfo(id: "com.apple.keylayout.ABC", localizedName: "ABC", languages: ["en"], isASCIICapable: true),
            InputSourceInfo(id: "com.apple.inputmethod.Korean.2SetKorean", localizedName: names.korean, languages: ["ko"], isASCIICapable: false),
            InputSourceInfo(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", localizedName: names.hiragana, languages: ["ja"], isASCIICapable: false)
        ]
    }

    private static func render(to directory: URL) {
        for language in [AppLanguage.en, .ko] {
            Localization.apply(language)
            // suite 이름만 주면 ~/Library/Preferences에 실행마다 빈 파일이 남는다. 임시 경로에 두고 끝나면 지운다.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHue-screenshots-\(UUID().uuidString)")
            let defaults = UserDefaults(suiteName: file.path)!
            defer { try? FileManager.default.removeItem(at: file.appendingPathExtension("plist")) }

            let store = SettingsStore(defaults: defaults)
            store.update {
                $0.appLanguage = language
                $0.barHeight = 4
                $0.onAppSwitch = .restoreLast
                $0.resetOnEscape = true
                $0.onWindowSwitch = .restoreLast
                $0.showHUD = true
            }
            let actions = ScreenshotActions()
            // 번들 없이 렌더링하므로 버전도 예시 값을 쓴다. 실제 조회는 하지 않는다.
            let updates = UpdateChecker(currentVersion: "0.1.0", defaults: defaults)
            let model = SettingsModel(store: store, actions: actions, updates: updates) { demoSources(for: language) }
            model.reload()

            // The input method tab shows the input method in use, with its two modes added.
            let inputMethodDefaults = UserDefaults(suiteName: file.path + "-input-method")!
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + "-input-method.plist")) }
            let inputMethodStore = SettingsStore(defaults: inputMethodDefaults)
            inputMethodStore.update {
                $0.appLanguage = language
                $0.integrateInputMethod = true
                $0.routeInputMethodPair = true
            }
            let inputMethodActions = ScreenshotActions()
            inputMethodActions.inputMethodInstallationStatus = InputMethodInstallationStatus(hasPayload: true, isInstalled: true)
            inputMethodActions.inputMethodRoutingStatus = .active
            let inputMethodModel = SettingsModel(store: inputMethodStore, actions: inputMethodActions, updates: updates) {
                demoSources(for: language) + demoInputMethodSources(for: language)
            }
            inputMethodModel.reload()

            let folder = directory.appendingPathComponent(language.rawValue)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for tab in SettingsTab.allCases {
                let selectedModel = tab == .inputMethod ? inputMethodModel : model
                selectedModel.selectedTab = tab
                let view = SettingsView(model: selectedModel)
                write(render(view, size: SettingsView.size), to: folder.appendingPathComponent("settings-\(tab.rawValue).png"))
            }
        }
        Localization.apply(.system)
        renderHUDs(to: directory)
    }

    /// 전환 HUD: 기본색 중 ABC(파랑), 한국어(초록), 일본어(주황), Caps Lock(빨강).
    private static func renderHUDs(to directory: URL) {
        let settings = KeyHueSettings()
        let samples: [(String, RGBAColor)] = [
            ("abc", settings.color(for: .source(demoSources(for: .en)[0]))),
            ("korean", settings.color(for: .source(demoSources(for: .en)[1]))),
            ("japanese", settings.color(for: .source(demoSources(for: .en)[2]))),
            ("capslock", settings.capsLockColor)
        ]
        // 화면 밖에서는 HUD의 반투명 배경(hudWindow material)이 그려지지 않으므로,
        // 같은 크기·모서리·실루엣 배치로 실제 HUD처럼 어두운 배경 위에 그린다.
        let mask = ChameleonImage.hudMask ?? ChameleonImage.fallbackMask
        let size = HUDController.size
        for (name, color) in samples {
            let chameleon = ChameleonImage.tinted(mask, color: color)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor(srgbRed: 0.13, green: 0.14, blue: 0.18, alpha: 0.92).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20).fill()
                chameleon.draw(in: NSRect(x: (rect.width - 70) / 2, y: (rect.height - 64) / 2, width: 70, height: 64))
                return true
            }
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            write(rep, to: directory.appendingPathComponent("hud-\(name).png"))
        }
    }

    static func demoInputMethodSources(for language: AppLanguage) -> [InputSourceInfo] {
        let names = language == .ko ? ("KeyHue 실험 – 두벌식", "KeyHue 실험 – 영문") : ("KeyHue Spike – Korean", "KeyHue Spike – English")
        return [
            InputSourceInfo(id: InputMethodIntegration.hangulID, localizedName: names.0, languages: ["ko"], isASCIICapable: false),
            InputSourceInfo(id: InputMethodIntegration.latinID, localizedName: names.1, languages: ["en"], isASCIICapable: true)
        ]
    }

    /// 화면 밖 창에 올려 한 번 그린 뒤 비트맵으로 캡처한다(Retina 배율).
    private static func render<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep {
        // 화면 밖 창은 비활성으로 그려지므로(회색 토글) 활성 창 상태로 고정한다.
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        host.frame = NSRect(origin: .zero, size: size)
        let window = KeyableWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        // 활성(key) 창으로 그려야 토글·버튼이 회색(비활성)이 아닌 강조색으로 나온다.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        print(url.path)
    }
}

/// borderless 창은 기본적으로 key가 될 수 없어 활성 상태로 그려지지 않는다.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 스크린샷용: 권한이 모두 허용된 상태로 보여준다.
@MainActor
private final class ScreenshotActions: SettingsActions {
    var escapeResetStatus: FeatureStatus = .active
    var textFocusResetStatus: FeatureStatus = .off
    var windowSwitchResetStatus: FeatureStatus = .active
    var inputMethodInstallationStatus = InputMethodInstallationStatus(hasPayload: true)
    var isInputMethodOperationRunning = false
    var inputMethodRoutingStatus: FeatureStatus = .off
    var wrongLanguageStatus: FeatureStatus = .off
    var isWrongLanguageModelMissing = false
    var windowSwitchStalledApp: String?
    var isLaunchAtLoginEnabled = true
    var isSystemInputIndicatorHidden = true
    func refreshFeatureStatuses() {}
    func installInputMethod() {}
    func uninstallInputMethod() {}
    func openInputSourceSettings() {}
    func setInputMethodRouting(_ enabled: Bool) {}
    func pauseInputMethodIntegration() {}
    func setResetOnEscape(_ enabled: Bool) {}
    func setResetOnTextFocusLoss(_ enabled: Bool) {}
    func setWarnOnWrongLanguage(_ enabled: Bool) {}
    func setOnWindowSwitch(_ behavior: SwitchBehavior) {}
    func openInputMonitoringSettings() {}
    func openAccessibilitySettings() {}
    func setLaunchAtLogin(_ enabled: Bool) {}
    func setSystemInputIndicatorHidden(_ hidden: Bool) {}
    func forgetPerAppInputs() {}
    func showSettings() {}
    func showUpdates() {}
    func showInputMethodSettings() {}
    func showLogFile() {}
}
