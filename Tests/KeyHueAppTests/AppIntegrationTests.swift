import AppKit
import Foundation
import KeyHueCore
import SwiftUI
import Testing
@testable import KeyHueApp

/// 실제 macOS API를 쓰는 통합 테스트(ADR 0022). 화면이 있는 macOS 세션(로컬, GitHub macOS 러너)에서 돈다.

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
private func makeStore() -> SettingsStore {
    SettingsStore(defaults: UserDefaults(suiteName: "KeyHueAppTests.\(UUID().uuidString)")!)
}

// MARK: - State Bar 패널

@MainActor
@Suite("Overlay panels", .serialized)
struct OverlayControllerTests {
    private func settings(_ configure: (inout KeyHueSettings) -> Void = { _ in }) -> KeyHueSettings {
        var s = KeyHueSettings()
        configure(&s)
        return s
    }

    private func shown(_ overlay: OverlayController) -> [StateBarPanel] {
        overlay.panels.values.filter(\.isVisible)
    }

    @Test func onePanelPerScreenAtTheBottomEdge() {
        let overlay = OverlayController()
        overlay.start()
        let s = settings { $0.barHeight = 4 }
        overlay.apply(state: .source(.korean2Set), settings: s)
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }

        #expect(shown(overlay).count == NSScreen.screens.count)
        for screen in NSScreen.screens {
            let panel = overlay.panels[screen.displayID!]
            #expect(panel?.frame == ScreenGeometry.stateBarFrame(screenFrame: screen.frame, thickness: 4, position: .bottom))
        }
    }

    @Test func panelsNeverTakeInputOrFocus() throws {
        let overlay = OverlayController()
        overlay.start()
        overlay.apply(state: .source(.abc), settings: settings())
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }

        let panel = try #require(overlay.panels.values.first)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.hasShadow)
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
    }

    @Test func colorFollowsStateAndOpacity() throws {
        let overlay = OverlayController()
        overlay.start()
        let s = settings { $0.barOpacity = 0.6 }
        overlay.apply(state: .source(.korean2Set), settings: s)
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }

        let color = try #require(overlay.panels.values.first?.backgroundColor.rgbaColor)
        let expected = s.barColor(for: .source(.korean2Set))
        #expect(abs(color.green - expected.green) < 0.01)
        #expect(abs(color.alpha - 0.6) < 0.01)

        overlay.apply(state: .capsLock, settings: s)
        let caps = try #require(overlay.panels.values.first?.backgroundColor.rgbaColor)
        #expect(abs(caps.red - s.capsLockColor.red) < 0.01)
    }

    @Test func positionAndHide() throws {
        let overlay = OverlayController()
        overlay.start()
        overlay.apply(state: .source(.abc), settings: settings { $0.barPosition = .top; $0.barHeight = 6 })
        let screen = try #require(NSScreen.screens.first)
        let panel = try #require(overlay.panels[screen.displayID!])
        #expect(panel.frame.maxY == screen.frame.maxY)
        #expect(panel.frame.height == 6)

        overlay.apply(state: .source(.abc), settings: settings { $0.showStateBar = false })
        #expect(shown(overlay).isEmpty)
    }

    @Test func activeScreenPolicyShowsOnePanel() {
        let overlay = OverlayController()
        overlay.start()
        overlay.setActiveScreen(NSScreen.main)
        overlay.apply(state: .source(.abc), settings: settings { $0.displayPolicy = .activeScreen })
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }
        #expect(shown(overlay).count == 1)
    }
}

// MARK: - 입력 소스 (TIS)

@MainActor
@Suite("Input sources")
struct InputSourceControllerTests {
    @Test func currentSourceIsReadable() throws {
        let current = try #require(InputSourceController.current())
        #expect(!current.id.isEmpty)
    }

    @Test func enabledSourcesIncludeTheCurrentOneAndALatinLayout() {
        let sources = InputSourceController.enabledSources()
        #expect(!sources.isEmpty)
        #expect(sources.contains { $0.isASCIIBase })
        if let current = InputSourceController.current() {
            #expect(sources.contains { $0.id == current.id })
        }
        #expect(InputSourceController.resolvedDefaultSource(preferredID: nil) != nil)
    }

    @Test func unknownPreferredSourceFallsBackToAutomatic() {
        let automatic = InputSourceController.resolvedDefaultSource(preferredID: nil)
        #expect(InputSourceController.resolvedDefaultSource(preferredID: "does.not.exist") == automatic)
    }

    @Test func systemSwitcherReportsTheSameSourceAsTIS() {
        #expect(SystemInputSourceSwitcher().currentSource == InputSourceController.current())
        #expect(!SystemInputSourceSwitcher().perform(.none))
    }
}

// MARK: - 번역 번들

@Suite("Localization bundle", .serialized)
struct LocalizationBundleTests {
    let resources = Bundle(path: repoRoot.appendingPathComponent("Resources").path)!

    @Test func appLanguageOverridesTheOSLanguage() {
        defer { Localization.apply(.system) }
        Localization.apply(.ko, in: resources)
        #expect(L("Show State Bar") == "상태 바 표시")
        #expect(L("Current Input: %@", "ABC") == "현재 입력: ABC")
        Localization.apply(.ja, in: resources)
        #expect(L("Show State Bar") == "状態バーを表示")
        Localization.apply(.en, in: resources)
        #expect(L("Show State Bar") == "Show State Bar")
    }

    @Test func missingTranslationFallsBackToTheEnglishKey() {
        defer { Localization.apply(.system) }
        Localization.apply(.ko, in: Bundle(path: NSTemporaryDirectory())!) // lproj가 없는 번들
        #expect(L("Show State Bar") == "Show State Bar")
    }
}

// MARK: - 설정 창 모델

@MainActor
private final class RecordingActions: StatusBarActions {
    var escapeResetStatus: FeatureStatus = .off
    var textFocusResetStatus: FeatureStatus = .off
    var isLaunchAtLoginEnabled = false
    var calls: [String] = []
    func setResetOnEscape(_ enabled: Bool) { calls.append("escape:\(enabled)") }
    func setResetOnTextFocusLoss(_ enabled: Bool) { calls.append("textFocus:\(enabled)") }
    func openInputMonitoringSettings() { calls.append("openInputMonitoring") }
    func openAccessibilitySettings() { calls.append("openAccessibility") }
    func setLaunchAtLogin(_ enabled: Bool) { calls.append("login:\(enabled)"); isLaunchAtLoginEnabled = enabled }
    func forgetPerAppInputs() { calls.append("forget") }
    func showSettings() { calls.append("settings") }
}

@MainActor
@Suite("Settings model")
struct SettingsModelTests {
    private func make() -> (SettingsModel, SettingsStore, RecordingActions) {
        let store = makeStore()
        let actions = RecordingActions()
        let model = SettingsModel(store: store, actions: actions) { [.abc, .korean2Set, .hiragana] }
        model.reload()
        return (model, store, actions)
    }

    @Test func reloadUsesInjectedSources() {
        let (model, _, _) = make()
        #expect(model.sources.map(\.id) == [InputSourceInfo.abc, .korean2Set, .hiragana].map(\.id))
        #expect(model.automaticDefaultName == "ABC")
    }

    @Test func bindingsWriteThroughToTheStore() {
        let (model, store, _) = make()
        model.binding(\.barHeight).wrappedValue = 8
        model.binding(\.barPosition).wrappedValue = .top
        #expect(store.settings.barHeight == 8)
        #expect(store.settings.barPosition == .top)
        #expect(model.settings.barHeight == 8) // 저장소 변경이 모델로 다시 반영된다
    }

    @Test func defaultSourceBindingMapsEmptyToAutomatic() {
        let (model, store, _) = make()
        model.defaultSourceBinding.wrappedValue = InputSourceInfo.korean2Set.id
        #expect(store.settings.defaultSourceID == InputSourceInfo.korean2Set.id)
        #expect(model.resolvedDefaultName == "2-Set Korean")
        model.defaultSourceBinding.wrappedValue = ""
        #expect(store.settings.defaultSourceID == nil)
    }

    @Test func colorBindingStoresOverrideAndResetClearsIt() {
        let (model, store, _) = make()
        model.colorBinding(.source(.hiragana)).wrappedValue = Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        #expect(store.settings.sourceColors[InputSourceInfo.hiragana.id]?.hexString == "#FF0000")
        #expect(model.isCustomized(.hiragana))
        model.resetColor(.hiragana)
        #expect(!model.isCustomized(.hiragana))

        model.colorBinding(.capsLock).wrappedValue = Color(nsColor: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        #expect(store.settings.capsLockColor.hexString == "#0000FF")
        model.resetAllColors()
        #expect(store.settings.capsLockColor == .defaultCapsLock)
    }

    @Test func permissionTogglesGoThroughActions() {
        let (model, _, actions) = make()
        model.escapeBinding.wrappedValue = true
        model.textFocusBinding.wrappedValue = true
        model.launchAtLoginBinding.wrappedValue = true
        model.openInputMonitoring()
        model.forgetPerAppInputs()
        #expect(actions.calls == ["escape:true", "textFocus:true", "login:true", "openInputMonitoring", "forget"])
        #expect(model.launchAtLogin)
    }
}

// MARK: - 앱 메뉴, 권한 화면

@MainActor
@Suite("App menu and permissions")
struct AppMenuTests {
    final class Target: NSObject {
        @objc func settings() {}
        @objc func about() {}
    }

    @Test func mainMenuHasStandardShortcuts() throws {
        let target = Target()
        let menu = MainMenu.make(target: target, showSettings: #selector(Target.settings), showAbout: #selector(Target.about))
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        func key(_ selector: Selector) -> String? { items.first { $0.action == selector }?.keyEquivalent }
        #expect(key(#selector(Target.settings)) == ",")
        #expect(key(#selector(NSApplication.terminate(_:))) == "q")
        #expect(key(#selector(NSWindow.performClose(_:))) == "w")
        #expect(key(#selector(NSText.copy(_:))) == "c")
        #expect(items.first { $0.action == #selector(Target.settings) }?.target === target)
    }

    @Test func permissionSettingsURLsPointToTheRightPanes() {
        #expect(PermissionKind.inputMonitoring.settingsURL.absoluteString.hasSuffix("Privacy_ListenEvent"))
        #expect(PermissionKind.accessibility.settingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
    }
}

// MARK: - 알림 전달 규칙 (ADR 0023)

@Suite("Notification delivery")
struct NotificationDeliveryRuleTests {
    /// KeyHue는 거의 항상 비활성 상태라, distributed notification을 기본 설정(모아서 늦게 전달)으로 받으면
    /// 한/영 전환이 최대 1.5초 늦게 반영된다(실측). 모든 구독은 selector API + .deliverImmediately여야 한다.
    @Test func distributedNotificationsAreDeliveredImmediately() throws {
        let sources = repoRoot.appendingPathComponent("Sources/KeyHueApp")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var subscriptions = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("DistributedNotificationCenter.default().addObserver") else { continue }
            let blocks = text.components(separatedBy: "DistributedNotificationCenter.default().addObserver").dropFirst()
            for block in blocks {
                subscriptions += 1
                let call = String(block.prefix(400))
                #expect(!call.hasPrefix("(forName:"), "\(file.lastPathComponent): 블록 API는 알림을 늦게 받을 수 있다")
                #expect(call.contains("suspensionBehavior: .deliverImmediately"), "\(file.lastPathComponent)")
            }
        }
        // InputSourceMonitor는 center 변수를 쓰므로 따로 확인
        let monitor = try String(contentsOf: sources.appendingPathComponent("Monitors/InputSourceMonitor.swift"), encoding: .utf8)
        #expect(monitor.contains("suspensionBehavior: .deliverImmediately"))
        #expect(!monitor.contains("addObserver(forName:"))
        #expect(subscriptions >= 1)
    }
}

// MARK: - 전환 HUD (ADR 0024)

@MainActor
@Suite("Chameleon HUD", .serialized)
struct HUDTests {
    /// 왼쪽 절반은 불투명, 오른쪽 절반은 투명한 마스크.
    private func halfMask() -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: rect.width / 2, height: rect.height).fill()
            return true
        }
    }

    /// 색 공간을 sRGB로 못 박은 비트맵에 그려서 읽는다(cgImage(forProposedRect:)는 색 공간 태그가 없어 값이 틀어진다).
    private func pixel(_ image: NSImage, x: Int, y: Int) -> NSColor? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.retagging(with: .sRGB) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: x, y: 19 - y)?.usingColorSpace(.sRGB)
    }

    @Test func tintPaintsOnlyTheSilhouette() throws {
        let color = RGBAColor(hex: "#34C759")!
        let tinted = ChameleonImage.tinted(halfMask(), color: color)
        let inside = try #require(pixel(tinted, x: 5, y: 10))
        #expect(abs(inside.greenComponent - color.green) < 0.04) // 색 관리 반올림 오차(약 6/255) 허용
        #expect(abs(inside.redComponent - color.red) < 0.04)
        let outside = try #require(pixel(tinted, x: 15, y: 10))
        #expect(outside.alphaComponent < 0.01)
    }

    @Test func showsTintedChameleonThenHides() async throws {
        let hud = HUDController(mask: halfMask())
        hud.prepare()
        hud.show(color: RGBAColor(hex: "#FF9500")!, on: NSScreen.main)
        #expect(hud.isShowing)
        let image = try #require(hud.image)
        let inside = try #require(pixel(image, x: 5, y: 10))
        #expect(abs(inside.redComponent - 1) < 0.04)

        try await Task.sleep(for: .seconds(HUDController.displayDuration + HUDController.fadeDuration + 0.3))
        #expect(!hud.isShowing)
    }

    @Test func rapidSwitchesKeepItVisible() async throws {
        let hud = HUDController(mask: halfMask())
        hud.show(color: RGBAColor(hex: "#0A84FF")!, on: NSScreen.main)
        try await Task.sleep(for: .seconds(HUDController.displayDuration * 0.7))
        hud.show(color: RGBAColor(hex: "#34C759")!, on: NSScreen.main) // 사라지기 전에 다시 전환
        try await Task.sleep(for: .seconds(HUDController.displayDuration * 0.7))
        #expect(hud.isShowing)
        try await Task.sleep(for: .seconds(HUDController.displayDuration + HUDController.fadeDuration + 0.3))
        #expect(!hud.isShowing)
    }

    @Test func staysBriefByDesign() {
        // "사라질 때 딜레이" 제보로 0.5 + 0.15초에서 줄였다.
        #expect(HUDController.displayDuration + HUDController.fadeDuration <= 0.5)
    }
}
