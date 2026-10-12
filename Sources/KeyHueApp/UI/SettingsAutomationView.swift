import KeyHueCore
import SwiftUI

struct AutomationSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            // 앱·창을 바꿀 때 각각 하나만 고른다(ADR 0029)
            Section {
                if let notice = model.defaultSourceNotice {
                    WarningLabel(notice)
                }
                Picker(L("When Switching Apps"), selection: model.binding(\.onAppSwitch)) {
                    behaviorChoices
                }
                Picker(L("When Switching Windows in the Same App"), selection: model.windowSwitchBinding) {
                    behaviorChoices
                }
                if let app = model.statuses.windowSwitchStalledApp {
                    WarningLabel(SharedText.windowSwitchStalled(in: app))
                }
                if model.statuses.windowSwitch == .needsPermission {
                    PermissionRow(message: L("Accessibility access is required."), action: model.openAccessibility)
                }
                if model.settings.rememberInputPerApp || model.settings.rememberInputPerWindow {
                    Button(L("Forget Remembered Inputs"), action: model.forgetPerAppInputs)
                }
            } footer: {
                Hint(L("Restore brings back the input source you last used in that app or window."),
                     details: L("Restore brings back the input source you last used in that app or window; apps and windows KeyHue hasn't seen switch to %@. Coming back from another app follows When Switching Apps, so with Keep As Is the front window keeps the current input source. Windows are remembered only until KeyHue quits. The window option needs Accessibility access: KeyHue only notices that the main window changed and never reads window titles or contents.", model.resolvedDefaultName))
            }

            Section {
                Toggle(L("Switch to %@ on ESC", model.resolvedDefaultName), isOn: model.escapeBinding)
                if model.statuses.escape == .needsPermission {
                    PermissionRow(message: SharedText.inputMonitoringRequired, action: model.openInputMonitoring)
                }
                Toggle(isOn: model.textFocusBinding) {
                    ExperimentalLabel(L("Switch to %@ When Leaving Text Field", model.resolvedDefaultName))
                }
                if model.statuses.textFocus == .needsPermission {
                    PermissionRow(message: L("Accessibility access is required."), action: model.openAccessibility)
                }
            } footer: {
                Hint(L("ESC needs Input Monitoring access; leaving a text field needs Accessibility access."),
                     details: L("KeyHue only checks whether the pressed key is ESC. It never reads, stores, or sends what you type.")
                        + "\n\n" + L("Experimental. Requires Accessibility access. KeyHue only reads the focused element's role, never its contents."))
            }
        }
        .formStyle(.grouped)
    }

    private var behaviorChoices: some View {
        ForEach(SwitchBehavior.allCases, id: \.self) { behavior in
            Text(behavior.title(defaultName: model.resolvedDefaultName)).tag(behavior)
        }
    }
}

/// ADR 0069: the input method, word fixing and the mix-up warning in one tab.
/// The input method shows one status line and one next step; rare actions are in Manage.
