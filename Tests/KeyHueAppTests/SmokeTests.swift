import Testing
@testable import KeyHueApp

@MainActor
@Suite("KeyHueApp smoke")
struct SmokeTests {
    @Test func screenshotFlagIsStable() {
        #expect(DocScreenshots.flag == "--render-screenshots")
    }
}
