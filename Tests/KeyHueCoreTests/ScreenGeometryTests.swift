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

    // MARK: 전환 HUD·경고 메시지 화면 (ADR 0063)

    /// 사용자 환경과 같은 세 모니터: 주 화면(내장) 왼쪽에 외부 모니터 두 대.
    let farLeft = CGRect(x: -3840, y: 0, width: 1920, height: 1200)
    let nearLeft = CGRect(x: -1920, y: 0, width: 1920, height: 1200)

    /// 한 앱의 창이 여러 모니터에 있을 때 앱 전환 없이 다른 모니터 창으로 옮긴 경우.
    /// 앱 전환 때 구해 둔 화면은 낡았으므로 키보드 포커스가 있는 화면을 쓴다.
    @Test func noticeFollowsTheKeyboardFocusOverTheScreenFoundAtAppSwitch() {
        let screens = [builtIn, farLeft, nearLeft]
        #expect(ScreenGeometry.noticeScreenIndex(focusedScreen: nearLeft, activeAppScreen: builtIn, screens: screens) == 2)
        #expect(ScreenGeometry.noticeScreenIndex(focusedScreen: builtIn, activeAppScreen: nearLeft, screens: screens) == 0)
    }

    @Test func noticeFallsBackToTheActiveAppScreenWithoutAFocusScreen() {
        #expect(ScreenGeometry.noticeScreenIndex(focusedScreen: nil, activeAppScreen: nearLeft, screens: [builtIn, nearLeft]) == 1)
    }

    /// 빠진 모니터에는 띄우지 않는다.
    @Test func disconnectedScreensAreNotUsedForNotices() {
        #expect(ScreenGeometry.noticeScreenIndex(focusedScreen: farLeft, activeAppScreen: nearLeft, screens: [builtIn, nearLeft]) == 1)
        #expect(ScreenGeometry.noticeScreenIndex(focusedScreen: farLeft, activeAppScreen: farLeft, screens: [builtIn, nearLeft]) == 0)
        #expect(ScreenGeometry.noticeScreenIndex(focusedScreen: nil, activeAppScreen: nil, screens: [nearLeft, builtIn]) == 0)
        #expect(ScreenGeometry.noticeScreenIndex(focusedScreen: builtIn, activeAppScreen: builtIn, screens: []) == nil)
    }

    /// HUD는 고른 화면의 사용 가능 영역 가운데 아래에 놓인다(Dock·메뉴바 제외).
    @Test func hudIsCenteredNearTheBottomOfTheChosenScreen() {
        let visible = CGRect(x: -1920, y: 0, width: 1920, height: 1170)
        let size = CGSize(width: 104, height: 96)
        let frame = ScreenGeometry.hudFrame(visibleFrame: visible, size: size, bottomOffset: 140)
        #expect(frame == CGRect(x: -960 - 52, y: 140, width: 104, height: 96))
        #expect(visible.contains(frame))
    }
}
