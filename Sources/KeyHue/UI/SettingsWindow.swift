import AppKit
import Carbon
import KeyHueCore
import SwiftUI

/// 설정 창의 상태. SettingsStore를 SwiftUI에 연결한다(ADR 0015).
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: KeyHueSettings
    @Published private(set) var sources: [InputSourceInfo] = []
    @Published private(set) var escapeStatus: FeatureStatus = .off
    @Published private(set) var textFocusStatus: FeatureStatus = .off
    @Published private(set) var launchAtLogin = false

    private let store: SettingsStore
    private weak var actions: StatusBarActions?
    /// 켜진 입력 소스 목록. 스크린샷 렌더링에서는 예시 목록으로 바꾼다.
    private let sourcesProvider: @MainActor () -> [InputSourceInfo]
    private var sourcesObserver: NSObjectProtocol?

    init(
        store: SettingsStore,
        actions: StatusBarActions,
        sourcesProvider: @escaping @MainActor () -> [InputSourceInfo] = InputSourceController.enabledSources
    ) {
        self.store = store
        self.actions = actions
        self.sourcesProvider = sourcesProvider
        self.settings = store.settings
        store.addObserver { [weak self] _, new in
            self?.settings = new
            self?.refreshStatuses()
        }
        // 시스템 설정에서 입력 소스를 추가/삭제하면 목록을 갱신한다.
        if let name = kTISNotifyEnabledKeyboardInputSourcesChanged as String? {
            sourcesObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func reload() {
        sources = sourcesProvider()
        refreshStatuses()
    }

    private func refreshStatuses() {
        escapeStatus = actions?.escapeResetStatus ?? .off
        textFocusStatus = actions?.textFocusResetStatus ?? .off
        launchAtLogin = actions?.isLaunchAtLoginEnabled ?? false
    }

    // MARK: Bindings

    func binding<Value>(_ keyPath: WritableKeyPath<KeyHueSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.store.update { $0[keyPath: keyPath] = value } }
        )
    }

    func colorBinding(_ target: ColorTarget) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(target.color(in: self.settings))) },
            set: { color in
                guard let rgba = NSColor(color).rgbaColor else { return }
                self.store.update { target.setColor(rgba, in: &$0) }
            }
        )
    }

    var defaultSourceBinding: Binding<String> {
        Binding(
            get: { self.settings.defaultSourceID ?? "" },
            set: { id in self.store.update { $0.defaultSourceID = id.isEmpty ? nil : id } }
        )
    }

    var escapeBinding: Binding<Bool> {
        Binding(get: { self.settings.resetOnEscape }, set: { self.actions?.setResetOnEscape($0) })
    }

    var textFocusBinding: Binding<Bool> {
        Binding(get: { self.settings.resetOnTextFocusLoss }, set: { self.actions?.setResetOnTextFocusLoss($0) })
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { self.launchAtLogin },
            set: { enabled in
                self.actions?.setLaunchAtLogin(enabled)
                self.refreshStatuses()
            }
        )
    }

    // MARK: Actions

    func isCustomized(_ source: InputSourceInfo) -> Bool {
        settings.sourceColors[source.id] != nil
    }

    func resetColor(_ source: InputSourceInfo) {
        store.update { $0.resetColor(for: source) }
    }

    func resetAllColors() {
        store.update { $0.resetColors() }
    }

    func forgetPerAppInputs() {
        actions?.forgetPerAppInputs()
    }

    func openInputMonitoring() {
        actions?.openInputMonitoringSettings()
    }

    func openAccessibility() {
        actions?.openAccessibilitySettings()
    }

    var automaticDefaultName: String {
        DefaultInputSourcePicker.pick(from: sources)?.displayName ?? "ABC"
    }

    var resolvedDefaultName: String {
        DefaultInputSourcePicker.pick(from: sources, preferredID: settings.defaultSourceID)?.displayName ?? "ABC"
    }
}

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        model.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func updateTitle() {
        window?.title = L("KeyHue Settings")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = L("KeyHue Settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

// MARK: - Views

enum SettingsTab: String, CaseIterable {
    case general
    case sources
    case automation
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State var tab: SettingsTab = .general

    static let size = CGSize(width: 540, height: 580)

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(model: model)
                .tabItem { Label(L("General"), systemImage: "gearshape") }
                .tag(SettingsTab.general)
            InputSourcesSettingsView(model: model)
                .tabItem { Label(L("Input Sources"), systemImage: "keyboard") }
                .tag(SettingsTab.sources)
            AutomationSettingsView(model: model)
                .tabItem { Label(L("Automation"), systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.automation)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: model.binding(\.appLanguage)) {
                    Text(L("System Default")).tag(AppLanguage.system)
                    ForEach(AppLanguage.allCases.filter { $0 != .system }, id: \.self) { language in
                        Text(language.nativeName ?? language.rawValue).tag(language)
                    }
                }
            } footer: {
                FooterText(L("Some system-provided text, such as input source names, follows the macOS language."))
            }

            Section(L("State Bar")) {
                Toggle(L("Show State Bar"), isOn: model.binding(\.showStateBar))
                Picker(L("Bar Position"), selection: model.binding(\.barPosition)) {
                    ForEach(BarPosition.allCases, id: \.self) { position in
                        Text(StatusBarController.title(for: position)).tag(position)
                    }
                }
                Picker(L("Bar Thickness"), selection: model.binding(\.barHeight)) {
                    ForEach(KeyHueSettings.barHeightChoices, id: \.self) { height in
                        Text("\(Int(height))px").tag(height)
                    }
                }
                LabeledContent(L("Bar Opacity")) {
                    HStack {
                        Slider(value: model.binding(\.barOpacity), in: KeyHueSettings.barOpacityRange, step: 0.1)
                        Text("\(Int((model.settings.barOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker(L("Displays"), selection: model.binding(\.displayPolicy)) {
                    Text(L("All Displays")).tag(DisplayPolicy.allScreens)
                    Text(L("Active Display Only")).tag(DisplayPolicy.activeScreen)
                }
            }

            Section(L("Indicators")) {
                Toggle(L("Tint Menu Bar Icon"), isOn: model.binding(\.tintMenuBarIcon))
                Toggle(L("Show HUD on Change"), isOn: model.binding(\.showHUD))
            }

            Section {
                Toggle(L("Launch at Login"), isOn: model.launchAtLoginBinding)
            }
        }
        .formStyle(.grouped)
    }
}

private struct InputSourcesSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.sources, id: \.id) { source in
                    ColorRow(
                        title: source.displayName,
                        subtitle: source.id,
                        color: model.colorBinding(.source(source)),
                        onReset: model.isCustomized(source) ? { model.resetColor(source) } : nil
                    )
                }
                ColorRow(
                    title: L("Caps Lock"),
                    subtitle: L("Shown instead of the input source color while Caps Lock is on."),
                    color: model.colorBinding(.capsLock),
                    onReset: nil
                )
            } header: {
                Text(L("Colors"))
            } footer: {
                FooterText(L("Each input source enabled in System Settings › Keyboard › Input Sources gets its own color."))
            }

            Section {
                Button(L("Reset All Colors"), action: model.resetAllColors)
            }

            Section {
                Picker(L("Default Input Source"), selection: model.defaultSourceBinding) {
                    Text(L("Automatic (%@)", model.automaticDefaultName)).tag("")
                    ForEach(model.sources, id: \.id) { source in
                        Text(source.displayName).tag(source.id)
                    }
                }
            } footer: {
                FooterText(L("Automatic switching (app switch, ESC, leaving a text field) selects this input source."))
            }

            Section {
                Text(L("KeyHue follows the input source that macOS reports. Modes switched inside a single input method without changing the input source (for example Shift in some Chinese input methods) cannot be detected."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ColorRow: View {
    let title: String
    let subtitle: String
    let color: Binding<Color>
    let onReset: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let onReset {
                Button(L("Reset"), action: onReset)
                    .buttonStyle(.link)
            }
            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
        }
    }
}

private struct AutomationSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(L("Switch to %@ on App Switch", model.resolvedDefaultName), isOn: model.binding(\.resetOnAppSwitch))
                Toggle(L("Switch to %@ on ESC", model.resolvedDefaultName), isOn: model.escapeBinding)
                if model.escapeStatus == .needsPermission {
                    PermissionRow(message: L("Input Monitoring access is required."), action: model.openInputMonitoring)
                }
            } footer: {
                FooterText(L("KeyHue only checks whether the pressed key is ESC. It never reads, stores, or sends what you type."))
            }

            Section {
                Toggle(L("Remember Input per App"), isOn: model.binding(\.rememberInputPerApp))
                if model.settings.rememberInputPerApp {
                    Button(L("Forget Remembered Inputs"), action: model.forgetPerAppInputs)
                }
            }

            Section {
                Toggle(L("Switch to %@ When Leaving Text Field", model.resolvedDefaultName), isOn: model.textFocusBinding)
                if model.textFocusStatus == .needsPermission {
                    PermissionRow(message: L("Accessibility access is required."), action: model.openAccessibility)
                }
            } header: {
                Text(L("Experimental"))
            } footer: {
                FooterText(L("Experimental. Requires Accessibility access. KeyHue only reads the focused element's role, never its contents."))
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let message: String
    let action: () -> Void

    var body: some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Spacer()
            Button(L("Grant Access…"), action: action)
        }
    }
}

/// Form 섹션 footer. 여러 줄일 때 오른쪽 정렬되지 않도록 왼쪽에 맞춘다.
private struct FooterText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true) // 긴 문장이 한 줄로 잘리지 않도록
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
