import Foundation

/// 입력기 통합(ADR 0049·0071·0082)이 자동 전환에 주는 영향. 한 시점의 **저장된** 설정과 켜진 Source 목록만 보는
/// 순수 계산이다. 언제 전환하고 확인·재시도할지는 `AutoResetCoordinator`가 맡는다.
///
/// - 기억과 기본 입력 소스는 지금 쓰는 짝(KeyHue 모드 ↔ ABC·시스템 2벌식)으로 읽는다.
/// - 예약한 동작은 실행 직전 목록으로 다시 맞춘다(그사이 입력기가 지워졌을 수 있다).
/// - KeyHue 모드가 실행되지 않으면 시스템 Source로 한 번 대신한다.
struct IntegratedActionResolver {
    let settings: KeyHueSettings
    let sources: [InputSourceInfo]

    /// 정책에 넘길 설정: 기본 입력 소스를 지금 쓰는 짝으로 읽은 복사본.
    var effectiveSettings: KeyHueSettings {
        InputMethodIntegration.effectiveSettings(settings, sources: sources)
    }

    /// 기억한 Source ID를 지금 쓰는 짝으로 읽는다.
    func sourceID(_ id: String) -> String {
        InputMethodIntegration.sourceID(id, settings: settings, sources: sources)
    }

    /// 예약한 동작을 실행 직전의 목록으로 실제 동작으로 바꾼다. 바꿀 것이 없으면 `.none`.
    func resolve(_ requested: InputSourceAction, current: InputSourceInfo?) -> InputSourceAction {
        let mapped: InputSourceAction
        switch requested {
        case .none: mapped = .none
        case .select(let id): mapped = .select(sourceID: sourceID(id))
        case .selectDefault(let id):
            var preference = settings
            // The policy can have resolved the effective default before the mode
            // roster changed. Revert to the saved default if the pair disappeared.
            let saved = settings.defaultSourceID
            let resolvedFromSaved = id == InputMethodIntegration.latinID && (saved == nil || saved == InputMethodIntegration.abcID)
                || id == InputMethodIntegration.hangulID && saved == InputMethodIntegration.systemHangulID
            if settings.integrateInputMethod, resolvedFromSaved, !InputMethodIntegration.isAvailable(in: sources) {
                preference.defaultSourceID = settings.defaultSourceID
            } else {
                preference.defaultSourceID = id
            }
            mapped = .selectDefault(preferredID: InputMethodIntegration.effectiveSettings(preference, sources: sources).defaultSourceID)
        }
        return DefaultInputSourcePicker.resolve(
            mapped,
            from: sources,
            current: current,
            preferredDefaultID: effectiveSettings.defaultSourceID
        )
    }

    /// A registered mode may still fail to launch: the switch to it failed while integrated.
    func needsFallback(after action: InputSourceAction, ok: Bool) -> Bool {
        !ok && settings.integrateInputMethod && Self.targetsKeyHueMode(action)
    }

    /// KeyHue 모드 대신 한 번 시도할 동작. Try the saved default once, without routing that
    /// fallback back into the failing mode. 고를 시스템 Source가 없으면 `.none`(그대로 둔다).
    func fallback(current: InputSourceInfo?) -> InputSourceAction {
        let savedID = settings.defaultSourceID
        let fallbackID = InputMethodIntegration.isMode(savedID) ? nil : savedID
        let action = DefaultInputSourcePicker.resolve(.selectDefault(preferredID: fallbackID), from: sources,
                                                      current: current, preferredDefaultID: fallbackID)
        // Automatic picking can land on a KeyHue mode when no system Latin
        // layout is enabled. Choose among system sources only, or stay put.
        if case .selectDefault(let preferredID) = action,
           let picked = DefaultInputSourcePicker.pick(from: sources, preferredID: preferredID), InputMethodIntegration.isMode(picked.id) {
            return DefaultInputSourcePicker.pick(from: sources.filter { !InputMethodIntegration.isMode($0.id) }, preferredID: fallbackID)
                .map { .select(sourceID: $0.id) } ?? .none
        }
        return action
    }

    /// Selects one of the two KeyHue modes, which may fail to launch.
    private static func targetsKeyHueMode(_ action: InputSourceAction) -> Bool {
        switch action {
        case .none: return false
        case .select(let id): return InputMethodIntegration.isMode(id)
        case .selectDefault(let id): return InputMethodIntegration.isMode(id)
        }
    }
}
