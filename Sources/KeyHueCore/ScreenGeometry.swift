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

    /// 전환 HUD·한/영 경고 메시지를 띄울 화면의 index (ADR 0063).
    /// 표시 순간 키보드 포커스가 있는 화면을 먼저 쓴다. 앱 전환 때 구해 둔 화면은 같은 앱의
    /// 다른 모니터 창으로 옮기면 낡기 때문이다. 둘 다 연결돼 있지 않으면 주 화면이다.
    public static func noticeScreenIndex(focusedScreen: CGRect?, activeAppScreen: CGRect?, screens: [CGRect]) -> Int? {
        for candidate in [focusedScreen, activeAppScreen] {
            if let candidate, let index = screens.firstIndex(of: candidate) { return index }
        }
        return screens.isEmpty ? nil : 0
    }

    /// 화면 사용 가능 영역(Dock·메뉴바 제외)의 가운데 아래에 놓는 HUD frame.
    public static func hudFrame(visibleFrame: CGRect, size: CGSize, bottomOffset: CGFloat) -> CGRect {
        CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + bottomOffset,
               width: size.width, height: size.height)
    }

    /// 화면 가장자리에 붙는 State Bar의 frame (AppKit 좌표, y 위로 증가).
    /// thickness는 가로 배치에서는 높이, 세로 배치에서는 폭이다.
    public static func stateBarFrame(screenFrame: CGRect, thickness: CGFloat, position: BarPosition) -> CGRect {
        let f = screenFrame
        switch position {
        case .top:
            return CGRect(x: f.minX, y: f.maxY - thickness, width: f.width, height: thickness)
        case .bottom:
            return CGRect(x: f.minX, y: f.minY, width: f.width, height: thickness)
        case .left:
            return CGRect(x: f.minX, y: f.minY, width: thickness, height: f.height)
        case .right:
            return CGRect(x: f.maxX - thickness, y: f.minY, width: thickness, height: f.height)
        }
    }
}
