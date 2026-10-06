import KeyHueCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var updates: UpdateChecker

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

            Section {
                Toggle(L("Show in Dock"), isOn: model.binding(\.showDockIcon))
                Toggle(L("Launch at Login"), isOn: model.launchAtLoginBinding)
            } footer: {
                FooterText(L("When Show in Dock is off, KeyHue stays in the menu bar and appears in the Dock only while this window is open."))
            }

            Section {
                HStack {
                    Text(L("Current Version"))
                    Spacer()
                    Text(updates.currentVersion).foregroundStyle(.secondary)
                    Button(L("Check for Updates…")) { Task { await updates.checkNow() } }
                        .disabled(updates.state.isChecking)
                }
                Toggle(L("Automatically Check for Updates"), isOn: model.binding(\.automaticallyChecksForUpdates))
                if let url = updates.releaseURL {
                    Link(L("Download New Version v%@…", updates.state.availableVersion ?? ""), destination: url)
                }
            } header: {
                Text(L("Updates"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    FooterText(updates.statusText)
                    HStack(spacing: 4) {
                        Text(L("Last Checked") + ":")
                        if let date = updates.state.lastChecked {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        } else {
                            Text(L("Never"))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    FooterText(L("Checks GitHub once a day. Download and install updates yourself from the release page."))
                }
            }

            Section {
                Button(L("Show Log File"), action: model.showLogFile)
            } footer: {
                FooterText(L("KeyHue keeps a log of app and window switches and input source changes. Attach it when reporting a problem. It never contains what you type."))
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
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

            Section {
                Toggle(L("Tint Menu Bar Icon"), isOn: model.binding(\.tintMenuBarIcon))
                Toggle(L("Show HUD on Change"), isOn: model.binding(\.showHUD))
            } header: {
                Text(L("Indicators"))
            } footer: {
                FooterText(L("The HUD appears the moment you switch. It hides as soon as you start typing only when Switch to %@ on ESC is on, because that uses Input Monitoring.", model.resolvedDefaultName))
            }

            Section {
                Toggle(L("Hide macOS Input Source Indicator"), isOn: model.systemIndicatorBinding)
            } footer: {
                FooterText(L("The badge macOS shows next to the cursor when you switch input sources. This is a macOS setting that applies to all apps right away and stays after you remove KeyHue."))
            }
        }
        .formStyle(.grouped)
    }
}

struct InputSourcesSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.sources, id: \.id) { source in
                    // 내부 ID는 이름이 겹칠 때만 보여 구분하고, 평소에는 마우스를 올리면 보인다.
                    ColorRow(
                        title: source.displayName,
                        subtitle: model.hasDuplicateName(source) ? source.id : nil,
                        color: model.colorBinding(.source(source)),
                        onReset: model.isCustomized(source) ? { model.resetColor(source) } : nil
                    )
                    .help(source.id)
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
                    if let id = model.unavailableDefaultSourceID {
                        Text(L("Unavailable Input Source")).tag(id).disabled(true)
                    }
                    ForEach(model.defaultSourceMenu.choices, id: \.id) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
            } footer: {
                FooterText(L("Automatic switching (app or window switch, ESC, leaving a text field) selects this input source."))
                if let notice = model.defaultSourceNotice {
                    FooterText(notice)
                }
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
    let subtitle: String?
    let color: Binding<Color>
    let onReset: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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

