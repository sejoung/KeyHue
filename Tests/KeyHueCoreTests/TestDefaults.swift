import Foundation

/// 테스트용 UserDefaults. 테스트마다 비어 있고 서로 격리된다.
///
/// suite 이름을 임시 폴더의 **절대 경로**로 주면 plist가 그 폴더에 생긴다.
/// 이름만 주면(`KeyHueTests.<UUID>`) ~/Library/Preferences에 테스트마다 파일이 하나씩 쌓이고,
/// `removePersistentDomain`으로 지워도 빈 파일이 남는다(실측: 2천 개 넘게 쌓였다).
func makeTestDefaults() -> UserDefaults {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueTests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return UserDefaults(suiteName: directory.appendingPathComponent(UUID().uuidString).path)!
}
