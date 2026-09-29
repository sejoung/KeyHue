import KeyHueCore

/// 통합 테스트용 예시 입력 소스(Core 테스트의 것과 같다).
extension InputSourceInfo {
    static let abc = InputSourceInfo(id: "com.apple.keylayout.ABC", localizedName: "ABC", languages: ["en"], isASCIICapable: true)
    static let korean2Set = InputSourceInfo(
        id: "com.apple.inputmethod.Korean.2SetKorean", localizedName: "2-Set Korean", languages: ["ko"], isASCIICapable: false
    )
    static let hiragana = InputSourceInfo(
        id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", localizedName: "Hiragana", languages: ["ja"], isASCIICapable: false
    )
}
