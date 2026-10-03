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

    @Test func stateBarAtEachEdge() {
        func frame(_ position: BarPosition) -> CGRect {
            ScreenGeometry.stateBarFrame(screenFrame: external, thickness: 4, position: position)
        }
        #expect(frame(.top) == CGRect(x: 1512, y: 1436, width: 2560, height: 4))
        #expect(frame(.bottom) == CGRect(x: 1512, y: 0, width: 2560, height: 4))
        #expect(frame(.left) == CGRect(x: 1512, y: 0, width: 4, height: 1440))
        #expect(frame(.right) == CGRect(x: 4068, y: 0, width: 4, height: 1440))
    }

    @Test func stateBarStaysInsideScreen() {
        for position in BarPosition.allCases {
            let frame = ScreenGeometry.stateBarFrame(screenFrame: builtIn, thickness: 16, position: position)
            #expect(builtIn.contains(frame))
        }
    }

    // MARK: 엣지 케이스

    /// 주 화면 왼쪽에 있는 모니터(원점이 음수)와 위에 있는 모니터.
    let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let aboveScreen = CGRect(x: 0, y: 982, width: 1512, height: 982)

    @Test func screensWithNegativeOriginAreMatched() {
        let screens = [builtIn, external, leftScreen]
        #expect(ScreenGeometry.bestScreenIndex(for: CGRect(x: -1000, y: 100, width: 400, height: 300), screens: screens) == 2)
        // 왼쪽 모니터와 주 화면에 걸쳐 있으면 많이 겹치는 쪽
        #expect(ScreenGeometry.bestScreenIndex(for: CGRect(x: -300, y: 100, width: 400, height: 300), screens: screens) == 2)
        #expect(ScreenGeometry.bestScreenIndex(for: CGRect(x: -100, y: 100, width: 400, height: 300), screens: screens) == 0)
    }

    @Test func windowAcrossThreeScreensPicksTheLargestShare() {
        let window = CGRect(x: -100, y: 0, width: 1512 + 100 + 300, height: 900)
        #expect(ScreenGeometry.bestScreenIndex(for: window, screens: [leftScreen, builtIn, external]) == 1)
    }

    @Test func touchingAnEdgeIsNotOverlap() {
        // 화면 경계에 딱 붙은 창은 그 화면과 겹치지 않는다
        let endsAtBuiltInRightEdge = CGRect(x: 1312, y: 100, width: 200, height: 200)
        #expect(ScreenGeometry.bestScreenIndex(for: endsAtBuiltInRightEdge, screens: [external, builtIn]) == 1)
        let startsAtExternal = CGRect(x: 1512, y: 100, width: 200, height: 200)
        #expect(ScreenGeometry.bestScreenIndex(for: startsAtExternal, screens: [builtIn, external]) == 1)
        let leftOfEverything = CGRect(x: -2020, y: 0, width: 100, height: 100)
        #expect(ScreenGeometry.bestScreenIndex(for: leftOfEverything, screens: [leftScreen, builtIn]) == nil)
        let aboveTheBuiltIn = CGRect(x: 0, y: 982, width: 100, height: 100)
        #expect(ScreenGeometry.bestScreenIndex(for: aboveTheBuiltIn, screens: [builtIn]) == nil)
    }

    @Test func degenerateInputsMatchNoScreen() {
        #expect(ScreenGeometry.bestScreenIndex(for: CGRect(x: 10, y: 10, width: 100, height: 100), screens: []) == nil)
        #expect(ScreenGeometry.bestScreenIndex(for: .null, screens: [builtIn]) == nil)
        #expect(ScreenGeometry.bestScreenIndex(for: CGRect(x: 10, y: 10, width: 0, height: 100), screens: [builtIn]) == nil)
        #expect(ScreenGeometry.bestScreenIndex(for: CGRect(x: 10, y: 10, width: 0, height: 0), screens: [builtIn]) == nil)
    }

    @Test func zeroSizeScreensAreIgnored() {
        let window = CGRect(x: 10, y: 10, width: 100, height: 100)
        #expect(ScreenGeometry.bestScreenIndex(for: window, screens: [.zero, builtIn]) == 1)
    }

    @Test func flipsWindowsOnScreensAboveAndLeftOfThePrimary() {
        // CG 좌표에서 주 화면 위 모니터는 y가 음수다. AppKit에서는 주 화면 높이 위쪽이 된다.
        let onAbove = CGRect(x: 100, y: -982, width: 400, height: 300)
        let flipped = ScreenGeometry.appKitRect(fromCGWindowBounds: onAbove, primaryScreenHeight: 982)
        #expect(flipped == CGRect(x: 100, y: 982 + 982 - 300, width: 400, height: 300))
        #expect(ScreenGeometry.bestScreenIndex(for: flipped, screens: [builtIn, aboveScreen]) == 1)

        let onLeft = CGRect(x: -1500, y: 0, width: 400, height: 300)
        #expect(ScreenGeometry.appKitRect(fromCGWindowBounds: onLeft, primaryScreenHeight: 982).minX == -1500)
    }

    @Test func flippingTwiceGivesTheOriginal() {
        let rects = [
            CGRect(x: 100, y: 50, width: 400, height: 300),
            CGRect(x: -1920, y: -500, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 0, height: 0)
        ]
        for rect in rects {
            let once = ScreenGeometry.appKitRect(fromCGWindowBounds: rect, primaryScreenHeight: 982)
            #expect(ScreenGeometry.appKitRect(fromCGWindowBounds: once, primaryScreenHeight: 982) == rect)
        }
    }

    @Test func stateBarOnANegativeOriginScreen() {
        let below = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        for position in BarPosition.allCases {
            let frame = ScreenGeometry.stateBarFrame(screenFrame: below, thickness: 3, position: position)
            #expect(below.contains(frame))
            #expect(position.isHorizontal ? frame.height == 3 && frame.width == 1920 : frame.width == 3 && frame.height == 1080)
        }
        #expect(ScreenGeometry.stateBarFrame(screenFrame: below, thickness: 3, position: .top).minY == -3)
        #expect(ScreenGeometry.stateBarFrame(screenFrame: below, thickness: 3, position: .right).minX == -3)
    }
}
