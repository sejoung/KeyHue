import KeyHueCore
import Testing
@testable import KeyHueApp

@Suite("Input method menu items")
struct InputMethodMenuStateTests {
    private let pair: [InputSourceInfo] = [
        InputSourceInfo(id: InputMethodIntegration.hangulID, localizedName: "KeyHue Korean", languages: ["ko"], isASCIICapable: false),
        InputSourceInfo(id: InputMethodIntegration.latinID, localizedName: "KeyHue English", languages: ["en"], isASCIICapable: true)
    ]

    private func installation(payload: Bool = true, installed: Bool = false, update: Bool = false, modes: Bool = false) -> InputMethodInstallationStatus {
        InputMethodInstallationStatus(hasPayload: payload, isInstalled: installed, needsUpdate: update, hasRegisteredSources: modes)
    }

    private func settings(integrate: Bool = false, route: Bool = false) -> KeyHueSettings {
        var settings = KeyHueSettings()
        settings.integrateInputMethod = integrate
        settings.routeInputMethodPair = route
        return settings
    }

    @Test func installTitleFollowsTheInstallation() {
        #expect(InputMethodMenuState(installation: installation(), isBusy: false, settings: settings(), sources: [], routingStatus: .off).installAction == .install)
        #expect(InputMethodMenuState(installation: installation(installed: true), isBusy: false, settings: settings(), sources: [], routingStatus: .off).installAction == .enable)
        #expect(InputMethodMenuState(installation: installation(installed: true, update: true), isBusy: false, settings: settings(), sources: [], routingStatus: .off).installAction == .update)
    }

    @Test func copyWithoutPayloadCannotInstallOrTurnIntegrationOn() {
        let state = InputMethodMenuState(installation: installation(payload: false), isBusy: false, settings: settings(), sources: [], routingStatus: .off)
        #expect(!state.isInstallEnabled)
        #expect(!state.isIntegrationEnabled)
        // Turning a saved integration off stays possible.
        #expect(InputMethodMenuState(installation: installation(payload: false), isBusy: false, settings: settings(integrate: true), sources: [], routingStatus: .off).isIntegrationEnabled)
    }

    @Test func uninstallIsShownForFilesOrLeftoverModes() {
        #expect(InputMethodMenuState(installation: installation(), isBusy: false, settings: settings(), sources: [], routingStatus: .off).isUninstallHidden)
        #expect(!InputMethodMenuState(installation: installation(installed: true), isBusy: false, settings: settings(), sources: [], routingStatus: .off).isUninstallHidden)
        #expect(!InputMethodMenuState(installation: installation(modes: true), isBusy: false, settings: settings(), sources: [], routingStatus: .off).isUninstallHidden)
    }

    @Test func runningOperationDisablesEveryAction() {
        let state = InputMethodMenuState(installation: installation(installed: true), isBusy: true, settings: settings(integrate: true), sources: pair, routingStatus: .active)
        #expect(!state.isInstallEnabled)
        #expect(!state.isUninstallEnabled)
        #expect(!state.isIntegrationEnabled)
        #expect(!state.isRoutingEnabled)
        #expect(!state.isNoticeEnabled)
    }

    @Test func integrationWaitingForTheUserToAddModesIsMixedWithANotice() {
        let waiting = InputMethodMenuState(installation: installation(installed: true), isBusy: false, settings: settings(integrate: true, route: true), sources: [pair[0]], routingStatus: .off)
        #expect(waiting.integration == .mixed)
        #expect(waiting.routing == .mixed)
        #expect(!waiting.isRoutingEnabled)
        #expect(!waiting.isNoticeHidden)
        #expect(!waiting.isRecoveryHidden)
        let ready = InputMethodMenuState(installation: installation(installed: true), isBusy: false, settings: settings(integrate: true, route: true), sources: pair, routingStatus: .active)
        #expect(ready.integration == .on)
        #expect(ready.routing == .on)
        #expect(ready.isRoutingEnabled)
        #expect(ready.isNoticeHidden)
    }

    @Test func routingNeedingPermissionShowsThePermissionItem() {
        let state = InputMethodMenuState(installation: installation(installed: true), isBusy: false, settings: settings(integrate: true, route: true), sources: pair, routingStatus: .needsPermission)
        #expect(state.routing == .mixed)
        #expect(!state.isRoutingPermissionHidden)
        #expect(InputMethodMenuState(installation: installation(installed: true), isBusy: false, settings: settings(integrate: true), sources: pair, routingStatus: .off).isRoutingPermissionHidden)
    }

    @Test func integrationOffHidesIntegrationItems() {
        let state = InputMethodMenuState(installation: installation(installed: true), isBusy: false, settings: settings(route: true), sources: pair, routingStatus: .off)
        #expect(state.integration == .off)
        #expect(state.routing == .off)
        #expect(!state.isRoutingEnabled)
        #expect(state.isNoticeHidden)
        #expect(state.isRecoveryHidden)
    }

    @MainActor
    @Test func everyStateRendersToAMenuCheckAndTitle() {
        #expect(StatusBarController.stateValue(.off) == .off)
        #expect(StatusBarController.stateValue(.on) == .on)
        #expect(StatusBarController.stateValue(.mixed) == .mixed)
        let titles = [InputMethodMenuState.InstallAction.install, .enable, .update].map(StatusBarController.title(for:))
        #expect(Set(titles).count == 3)
        #expect(!titles.contains(""))
    }
}
