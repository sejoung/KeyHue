import CoreGraphics

public enum ScreenGeometry {
    /// CGWindowList 좌표(좌상단 원점, y 아래로 증가)를 AppKit 좌표(좌하단 원점)로 변환한다.
    /// 기준은 메뉴바가 있는 주 화면(NSScreen.screens[0])의 높이다.
    public static func appKitRect(fromCGWindowBounds rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// 윈도우와 가장 많이 겹치는 화면의 index. 어느 화면과도 겹치지 않으면 nil.
    public static func bestScreenIndex(for windowRect: CGRect, screens: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let intersection = screen.intersection(windowRect)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if best == nil || area > best!.area {
                best = (index, area)
            }
        }
        return best?.index
    }

    /// 화면 최하단에 붙는 State Bar의 frame.
    public static func stateBarFrame(screenFrame: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: height)
    }
}
