import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

/// 설정 창과 메뉴는 같은 상태 구조체로 그린다. 같은 입력이면 같은 결과여야 한다.
@MainActor
@Suite("Settings window and menu agree")
struct SettingsMenuConsistencyTests {
    private static let pair: [InputSourceInfo] = [
        InputSourceInfo(id: InputMethodIntegration.hangulID, localizedName: "KeyHue Korean", languages: ["ko"], isASCIICapable: false),
        InputSourceInfo(id: InputMethodIntegration.latinID, localizedName: "KeyHue English", languages: ["en"], isASCIICapable: true)
    ]

    private static let us = InputSourceInfo(id: "com.apple.keylayout.US", localizedName: "U.S.", languages: ["en"], isASCIICapable: true)
    private static let german = InputSourceInfo(id: "com.apple.keylayout.German", localizedName: "German", languages: ["de"], isASCIICapable: true)

    private func makeModel(_ actions: StatusBarActions, store: SettingsStore, sources: [InputSourceInfo]) -> SettingsModel {
        let model = SettingsModel(
            store: store, actions: actions,
            updates: UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), scheduler: FakeScheduler()) {
                throw GitHubReleaseFetcher.Failure.invalidResponse
            }
        ) { sources }
        model.reload()
        return model
    }

    @Test func inputMethodItemsMatchTheMenuInEveryState() {
        let installations = [
            InputMethodInstallationStatus(),
            InputMethodInstallationStatus(hasPayload: true),
            InputMethodInstallationStatus(hasPayload: true, isInstalled: true),
            InputMethodInstallationStatus(hasPayload: true, isInstalled: true, needsUpdate: true),
            InputMethodInstallationStatus(hasPayload: false, isInstalled: false, needsUpdate: false, hasRegisteredSources: true)
        ]
        for installation in installations {
            for busy in [false, true] {
                for (integrate, route) in [(false, false), (true, false), (true, true)] {
                    for sources in [[InputSourceInfo.abc], [.abc] + Self.pair] {
                        for routing in [FeatureStatus.off, .active, .needsPermission] {
                            let actions = AppEdgeDecliningActions()
                            actions.inputMethodInstallationStatus = installation
                            actions.isInputMethodOperationRunning = busy
                            actions.inputMethodRoutingStatus = routing
                            let store = SettingsStore(defaults: makeTestDefaults())
                            store.update {
                                $0.integrateInputMethod = integrate
                                $0.routeInputMethodPair = route
                            }
                            let model = makeModel(actions, store: store, sources: sources)
                            let menu = InputMethodMenuState(installation: installation, isBusy: busy, settings: store.settings,
                                                            sources: sources, routingStatus: routing)
                            #expect(model.inputMethodMenu == menu)
                        }
                    }
                }
            }
        }
    }

    @Test func installButtonTitleIsShared() {
        for action in [InputMethodMenuState.InstallAction.install, .enable, .update] {
            #expect(StatusBarController.title(for: action) == action.title)
        }
    }

    @Test func defaultSourceChoicesMatchTheMenu() {
        let cases: [(String?, [InputSourceInfo])] = [
            (nil, [.korean2Set, .abc]),
            (Self.us.id, [.abc, Self.us]),
            (Self.german.id, [.abc]),                     // Removed default
            (nil, [.korean2Set]),                         // No Latin source
            (InputMethodIntegration.abcID, Self.pair)     // Read as KeyHue English while integrated
        ]
        for (saved, sources) in cases {
            let store = SettingsStore(defaults: makeTestDefaults())
            store.update {
                $0.defaultSourceID = saved
                $0.integrateInputMethod = true
            }
            let model = makeModel(AppEdgeDecliningActions(), store: store, sources: sources)
            let menu = DefaultSourceMenu(settings: store.settings, sources: sources)
            #expect(model.defaultSourceMenu == menu)
            #expect(model.unavailableDefaultSourceID == (menu.showsUnavailableChoice ? saved : nil))
            #expect((model.automaticDefaultName == menu.automaticName) || menu.automaticName == nil)
            #expect(model.defaultSourceMenu.choices.map(\.id) == sources.map(\.id))
        }
    }
}
