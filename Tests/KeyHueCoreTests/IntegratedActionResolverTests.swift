import Foundation
import Testing
@testable import KeyHueCore

/// 입력기 통합의 동작 변환과 실행 실패 대체(`IntegratedActionResolver`). 순수 계산이라 시간·전환기가 필요 없다.
@Suite("Integrated action resolver")
struct IntegratedActionResolverTests {
    private static let modes: [InputSourceInfo] = [.keyHueHangul, .keyHueLatin]
    /// KeyHue 영문 모드가 맨 앞이라 자동 선택이 그것을 고르는 제3자 영문 배열.
    private static let thirdPartyLatin = InputSourceInfo(id: "org.example.latin", localizedName: "Latin", languages: ["en"], isASCIICapable: true)

    private func resolver(
        integrate: Bool = true,
        defaultID: String? = nil,
        sources: [InputSourceInfo] = [.abc, .korean2Set] + modes
    ) -> IntegratedActionResolver {
        var settings = KeyHueSettings()
        settings.integrateInputMethod = integrate
        settings.defaultSourceID = defaultID
        return IntegratedActionResolver(settings: settings, sources: sources)
    }

    // MARK: 짝으로 읽기

    @Test func readsSystemPairAsKeyHueModesWhileIntegrated() {
        let r = resolver()
        #expect(r.sourceID(InputMethodIntegration.abcID) == InputMethodIntegration.latinID)
        #expect(r.sourceID(InputMethodIntegration.systemHangulID) == InputMethodIntegration.hangulID)
        #expect(r.effectiveSettings.defaultSourceID == InputMethodIntegration.latinID)
        #expect(r.settings.defaultSourceID == nil) // 저장된 설정은 그대로
    }

    @Test func readsKeyHueModesAsSystemPairWithoutIntegration() {
        let r = resolver(integrate: false)
        #expect(r.sourceID(InputMethodIntegration.latinID) == InputMethodIntegration.abcID)
        #expect(r.effectiveSettings.defaultSourceID == nil)
    }

    // MARK: 실행 직전 변환

    @Test func selectionOfSystemSourceTargetsItsKeyHueMode() {
        #expect(resolver().resolve(.select(sourceID: InputMethodIntegration.abcID), current: .korean2Set)
            == .select(sourceID: InputMethodIntegration.latinID))
    }

    @Test func defaultResolvedFromAutomaticFallsBackWhenThePairDisappeared() {
        // 예약할 때는 자동 기본값을 KeyHue 영문으로 읽었지만, 실행 직전에 모드가 사라졌다.
        let r = resolver(sources: [.abc, .korean2Set])
        #expect(r.resolve(.selectDefault(preferredID: InputMethodIntegration.latinID), current: .korean2Set)
            == .selectDefault(preferredID: nil))
        // 이미 영문 배열이면 바꾸지 않는다.
        #expect(r.resolve(.selectDefault(preferredID: InputMethodIntegration.latinID), current: .abc) == .none)
    }

    @Test func defaultResolvedFromSystemKoreanFallsBackToItWhenThePairDisappeared() {
        let r = resolver(defaultID: InputMethodIntegration.systemHangulID, sources: [.abc, .korean2Set])
        #expect(r.resolve(.selectDefault(preferredID: InputMethodIntegration.hangulID), current: .abc)
            == .selectDefault(preferredID: InputMethodIntegration.systemHangulID))
    }

    @Test func explicitDefaultIsKeptWhenAvailable() {
        let r = resolver(integrate: false, sources: [.abc, .german, .korean2Set])
        #expect(r.resolve(.selectDefault(preferredID: InputSourceInfo.german.id), current: .korean2Set)
            == .selectDefault(preferredID: InputSourceInfo.german.id))
        #expect(r.resolve(.none, current: .korean2Set) == .none)
    }

    // MARK: 실행 실패 대체

    @Test func onlyAFailedKeyHueModeWhileIntegratedNeedsAFallback() {
        let mode = InputSourceAction.select(sourceID: InputMethodIntegration.hangulID)
        #expect(resolver().needsFallback(after: mode, ok: false))
        #expect(resolver().needsFallback(after: .selectDefault(preferredID: InputMethodIntegration.latinID), ok: false))
        #expect(!resolver().needsFallback(after: mode, ok: true))
        #expect(!resolver().needsFallback(after: .select(sourceID: InputMethodIntegration.abcID), ok: false))
        #expect(!resolver().needsFallback(after: .selectDefault(preferredID: nil), ok: false))
        #expect(!resolver(integrate: false).needsFallback(after: mode, ok: false))
    }

    @Test func fallbackSkipsASavedKeyHueModeDefault() {
        let r = resolver(defaultID: InputMethodIntegration.hangulID)
        #expect(r.fallback(current: .keyHueHangul) == .selectDefault(preferredID: nil))
    }

    @Test func fallbackUsesASavedSystemDefault() {
        let r = resolver(defaultID: InputMethodIntegration.systemHangulID, sources: [.korean2Set] + Self.modes)
        #expect(r.fallback(current: .keyHueLatin) == .selectDefault(preferredID: InputMethodIntegration.systemHangulID))
    }

    @Test func fallbackNeverPicksAKeyHueModeAutomatically() {
        // 시스템 영문 배열이 없으면 자동 선택이 KeyHue 영문을 고른다: 시스템 Source 중에서만 고른다.
        let r = resolver(sources: [.keyHueLatin, .keyHueHangul, .korean2Set, Self.thirdPartyLatin])
        #expect(r.fallback(current: .korean2Set) == .select(sourceID: Self.thirdPartyLatin.id))
    }

    @Test func fallbackStaysPutWithoutASystemLatinSource() {
        let r = resolver(sources: [.korean2Set] + Self.modes)
        #expect(r.fallback(current: .korean2Set) == .none)
    }
}
