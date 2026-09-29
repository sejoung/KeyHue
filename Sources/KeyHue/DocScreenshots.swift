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
            let suite = "io.github.sejoung.keyhue.screenshots.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let store = SettingsStore(defaults: defaults)
            store.update {
                $0.appLanguage = language
                $0.barHeight = 4
                $0.resetOnAppSwitch = true
                $0.resetOnEscape = true
                $0.showHUD = true
            }
            let actions = ScreenshotActions()
            let model = SettingsModel(store: store, actions: actions) { demoSources(for: language) }
            model.reload()

            let folder = directory.appendingPathComponent(language.rawValue)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for tab in SettingsTab.allCases {
                let view = SettingsView(model: model, tab: tab)
                write(render(view, size: SettingsView.size), to: folder.appendingPathComponent("settings-\(tab.rawValue).png"))
            }
        }
        Localization.apply(.system)
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
private final class ScreenshotActions: StatusBarActions {
    var escapeResetStatus: FeatureStatus = .active
    var textFocusResetStatus: FeatureStatus = .off
    var isLaunchAtLoginEnabled = true
    func setResetOnEscape(_ enabled: Bool) {}
    func setResetOnTextFocusLoss(_ enabled: Bool) {}
    func openInputMonitoringSettings() {}
    func openAccessibilitySettings() {}
    func setLaunchAtLogin(_ enabled: Bool) {}
    func forgetPerAppInputs() {}
    func showSettings() {}
}
