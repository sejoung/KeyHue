import KeyHueCore
import SwiftUI

struct InputMethodSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            let state = model.inputMethodMenu
            Section {
                HStack {
                    Text(L("Status"))
                    Spacer()
                    if state.isBusy {
                        ProgressView().controlSize(.small)
                        Text(L("Managing Input Method…")).foregroundStyle(.secondary)
                    } else {
                        Text(state.phase.title).foregroundStyle(state.phase == .active ? .primary : .secondary)
                    }
                    if state.showsManageMenu {
                        Menu(L("Manage")) {
                            if !state.isRoutingHidden {
                                Toggle(L("Keep KeyHue Korean/English Modes"), isOn: model.inputMethodRoutingBinding)
                                    .disabled(!state.isRoutingEnabled)
                            }
                            if !state.isRecoveryHidden {
                                Button(L("Pause Integration and Switch to ABC"), action: model.pauseInputMethodIntegration)
                            }
                            if !state.isUninstallHidden {
                                Divider()
                                Button(L("Uninstall Input Method"), action: model.uninstallInputMethod)
                                    .disabled(!state.isUninstallEnabled)
                            }
                        }
                        .fixedSize()
                        .disabled(state.isBusy)
                    }
                }
                if let step = state.nextStep {
                    HStack {
                        Spacer()
                        Button(step.title) { model.perform(step) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!state.isNextStepEnabled)
                    }
                }
                if !state.isRoutingPermissionHidden {
                    PermissionRow(message: L("Input Monitoring access is required."), action: model.openInputMonitoring)
                }
            } header: {
                ExperimentalLabel(L("KeyHue Input Method"))
            } footer: {
                Hint(L("Korean (2-Set) and English modes made for KeyHue. After installing, add both modes in System Settings."),
                     details: [
                        L("KeyHue includes its input method. Turning this on installs or updates it for your user account. Add both KeyHue modes in System Settings → Keyboard → Text Input to start Korean/English integration. Before uninstalling, remove both modes there; uninstall removes only the input method and keeps your KeyHue settings."),
                        L("While both KeyHue modes are enabled, automatic or ABC defaults and remembered ABC use KeyHue English, and 2-Set Korean uses KeyHue Korean. When integration is off or a mode is missing, remembered KeyHue modes use ABC and 2-Set Korean again. Your saved settings remain unchanged. If selection fails, the original policy is used."),
                        L("ABC selected from a KeyHue mode is redirected to the other KeyHue mode, including manual ABC selection. Other languages are kept. Use Pause Integration and Switch to ABC to leave the pair. Very fast typing may arrive before macOS reports the switch."),
                        L("KeyHue observes input source changes for every switching method. Input Monitoring lets it cancel a pending switch when typing begins. It never reads, stores, or sends text for this option.")
                     ].joined(separator: "\n\n"))
            }

            // ADR 0064: the input method reads these; editable while the input method is used.
            Section {
                Picker(L("Fix Words Typed in the Wrong Input Mode"), selection: model.binding(\.inputMethodCorrection)) {
                    Text(L("Off")).tag(CorrectionMode.off)
                    Text(L("With the Shortcut")).tag(CorrectionMode.manual)
                    Text(L("With the Shortcut and Automatically at Space")).tag(CorrectionMode.automatic)
                }
                if model.showsAutoCapitalizationNotice {
                    PermissionRow(message: L("macOS capitalizes the first word of a sentence, so the fix shortcut can read a capital you didn't type (rk → Rk → 까). Turning off Capitalize words automatically in Keyboard › Text Input › Edit… is recommended."),
                                  buttonTitle: L("Open Keyboard Settings…"), action: model.openKeyboardSettings)
                }
                LabeledContent(L("Fix Shortcut")) {
                    ShortcutRecorder(shortcut: model.binding(\.correctionShortcut))
                }
                .disabled(model.settings.inputMethodCorrection == .off)
                DisclosureGroup(L("Apps That Are Never Changed (%@)", String(model.settings.correctionExcludedApps.count))) {
                    ForEach(model.settings.correctionExcludedApps, id: \.self) { bundleID in
                        HStack {
                            Text(model.appName(for: bundleID))
                            Spacer()
                            Button(L("Remove")) { model.removeExcludedApp(bundleID) }
                        }
                    }
                    HStack {
                        Button(L("Add App…"), action: model.chooseExcludedApps)
                        Button(L("Restore Defaults"), action: model.restoreDefaultExcludedApps)
                            .disabled(model.excludedAppsAreDefault)
                    }
                }
                CorrectionFeedbackView(model: model, feedback: model.feedback)
            } header: {
                ExperimentalLabel(L("Word Fixing"))
            } footer: {
                if !model.isCorrectionEditable {
                    FooterText(L("Available while the KeyHue input method is in use."))
                }
                Hint(L("Press the shortcut to fix a word typed in the wrong mode (dkssud → 안녕). Press it again right away to undo."),
                     details: L("Press the shortcut to fix text typed in the wrong input mode: the selection, or the word right before the cursor (dkssud → 안녕, ㅗ디ㅣㅐ → hello). KeyHue switches to the right mode; press the shortcut again right away to undo. With the Shortcut and Automatically at Space also fixes Korean typed in English mode when you press Space, when KeyHue thinks it was a mistake; press Delete right away to undo that. Password fields and the apps above are never changed; with automatic fixing, add code editors here if identifiers get changed.")
                        + "\n\n" + L("In terminals, KeyHue fixes the word you just typed by erasing it with Delete keys and typing the fix. KeyHue sends those keys, so it needs Accessibility access while it is running. Text stays in the input method's memory only; nothing is saved or sent."))
            }
            .disabled(!model.isCorrectionEditable)

            if model.showsWrongLanguageOption {
                Section {
                    Toggle(L("Warn When Korean and English Are Mixed Up"), isOn: model.wrongLanguageBinding)
                    if model.wrongLanguageStatus == .needsPermission {
                        PermissionRow(message: L("Input Monitoring access is required."), action: model.openInputMonitoring)
                    }
                    Toggle(L("Show a Message"), isOn: model.binding(\.wrongLanguageShowsMessage))
                        .disabled(!model.settings.warnOnWrongLanguage)
                        .padding(.leading, 16)
                    if model.wrongLanguageModelMissing {
                        Label(L("KeyHue couldn't load its Korean syllable model, so this option isn't working. Reinstalling KeyHue should fix it."),
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if model.wrongLanguageWarningIsInvisible {
                        Label(L("The bar is hidden, so warnings won't be visible. Show the bar or turn on Show a Message."),
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    // 한국어 사용자를 위한 기능임을 다른 언어 사용자에게도 분명히 한다
                    ExperimentalLabel(L("Korean Input"))
                } footer: {
                    Hint(L("The bar blinks when a word looks typed in the other mode. Nothing you type is changed."),
                         details: L("For Korean (2-Set) users, together with a QWERTY English layout. When a word looks like it's being typed in the other mode (dkssud → 안녕, ㅗ디ㅣㅐ → hello), KeyHue lets you know, usually within the first few keys: the bar blinks in that language's color and, if Show a Message is on, a message shows the word in that language. Nothing is changed or switched. KeyHue reads only key positions, keeps the current word in memory, and discards it when the word ends. Requires Input Monitoring access."))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// ADR 0065: exception words, undone fixes (only when recorded) and apps where fixing failed.
/// The first two only with automatic fixing (ADR 0068).
private struct CorrectionFeedbackView: View {
    let model: SettingsModel
    @ObservedObject var feedback: CorrectionFeedbackStore

    /// Exception words and undone fixes steer only automatic fixing (ADR 0068).
    @ViewBuilder private var detectorOptions: some View {
        if !model.settings.correctionIgnoredWords.isEmpty {
            DisclosureGroup(L("Words That Are Never Changed")) {
                ForEach(model.settings.correctionIgnoredWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(L("Remove")) { model.removeIgnoredWord(word) }
                    }
                }
            }
        }
        Toggle(L("Record Undone Fixes"), isOn: model.recordUndoneBinding)
            .help(L("When on, KeyHue keeps fixes you undid right away (what you typed, what it became, and the app) on this Mac only, up to 50. Turning it off deletes them. Reports open in your browser, and only for what you choose."))
        if model.settings.recordUndoneCorrections, !feedback.undone.isEmpty {
            DisclosureGroup(L("Undone Fixes")) {
                ForEach(feedback.undone, id: \.self) { entry in
                    HStack {
                        Text("\(entry.original) → \(entry.corrected)")
                        Text(model.appName(for: entry.app)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Never Fix This Word")) { model.neverCorrect(entry) }
                        Button(L("Report")) {
                            model.confirmReport(feedback.reportURL(for: entry),
                                                summary: "\(entry.original) → \(entry.corrected) · \(entry.app) · \(entry.mode.rawValue)")
                        }
                        Button(L("Delete")) { feedback.removeUndone(entry) }
                    }
                }
                Button(L("Delete All"), action: feedback.clearUndone)
            }
        }
    }

    var body: some View {
        if model.showsDetectorOptions {
            detectorOptions
        }
        if !feedback.failures.isEmpty {
            DisclosureGroup(L("Apps Where Fixing Failed")) {
                ForEach(feedback.failures, id: \.app) { record in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.appName(for: record.app))
                            Text(L("%@ times · %@", String(record.count), Self.reasonText(record.lastReason)))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if record.lastReason == .keyPermission {
                            Button(L("Allow…")) { model.allowTerminalFixing(record.app) }
                        }
                        Button(L("Exclude")) { model.excludeFailedApp(record.app) }
                        Button(L("Try Again")) { feedback.clearFailures(app: record.app) }
                        Button(L("Report")) {
                            model.confirmReport(feedback.reportURL(for: record),
                                                summary: "\(record.app) · \(record.lastReason.rawValue) · \(record.count)")
                        }
                    }
                }
            }
        }
    }

    static func reasonText(_ reason: CorrectionFailure) -> String {
        switch reason {
        case .textUnavailable: return L("The app didn't report the text")
        case .replacementIgnored: return L("The app ignored the replacement")
        case .unexpectedResult: return L("The result was different")
        case .modeNotApplied: return L("Korean mode wasn't applied")
        case .keyPermission: return L("KeyHue needs Accessibility access")
        case .nothingToFix: return L("No Word to Fix")
        case .terminalSelection: return L("Selected Text Can't Be Fixed Here")
        }
    }
}

