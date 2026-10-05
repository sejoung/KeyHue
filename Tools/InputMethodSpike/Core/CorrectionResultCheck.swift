import KeyHueCore

/// ADR 0065: why a manual correction did not show by its deadline, if the app is
/// to blame. The user changing the text or caret first is not an app failure.
public enum CorrectionResultCheck {
    public static func failure(afterRequest: Bool, textAvailable: Bool, originalStillThere: Bool) -> CorrectionFailure? {
        guard textAvailable else { return .textUnavailable }
        guard afterRequest else { return nil }
        return originalStillThere ? .replacementIgnored : .unexpectedResult
    }
}
