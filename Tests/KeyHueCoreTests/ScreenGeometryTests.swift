import CoreGraphics
import Testing
@testable import KeyHueCore

@Suite("Screen geometry")
struct ScreenGeometryTests {
    // 주 화면 1512x982, 오른쪽에 외부 모니터 2560x1440(하단 정렬)
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    @Test func flipsCGWindowBounds() {
        let cg = CGRect(x: 100, y: 50, width: 400, height: 300)
        let appKit = ScreenGeometry.appKitRect(fromCGWindowBounds: cg, primaryScreenHeight: 982)
        #expect(appKit == CGRect(x: 100, y: 982 - 50 - 300, width: 400, height: 300))
    }

    @Test func picksScreenWithLargestOverlap() {
        let window = CGRect(x: 1400, y: 100, width: 800, height: 600) // 대부분 외부 모니터
        #expect(ScreenGeometry.bestScreenIndex(for: window, screens: [builtIn, external]) == 1)
    }

    @Test func noOverlap() {
        let window = CGRect(x: -5000, y: -5000, width: 10, height: 10)
        #expect(ScreenGeometry.bestScreenIndex(for: window, screens: [builtIn, external]) == nil)
    }

    @Test func stateBarSitsAtBottomEdge() {
        let frame = ScreenGeometry.stateBarFrame(screenFrame: external, height: 3)
        #expect(frame == CGRect(x: 1512, y: 0, width: 2560, height: 3))
    }
}
