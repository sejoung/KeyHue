import AppKit
import KeyHueCore

/// 현재 활성 앱의 최전면 윈도우가 놓인 화면을 찾는다.
///
/// CGWindowList에서 소유 PID/레이어/bounds만 읽는다. 윈도우 제목(kCGWindowName)은 읽지 않으므로
/// Screen Recording 권한이 필요 없다.
@MainActor
enum ActiveScreenLocator {
    static func screen(forPID pid: pid_t?) -> NSScreen? {
        guard let pid, let bounds = frontWindowBounds(pid: pid) else {
            return NSScreen.main
        }
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let rect = ScreenGeometry.appKitRect(fromCGWindowBounds: bounds, primaryScreenHeight: primary.frame.height)
        let index = ScreenGeometry.bestScreenIndex(for: rect, screens: screens.map(\.frame))
        return index.map { screens[$0] } ?? NSScreen.main
    }

    /// 전환 HUD·한/영 경고 메시지를 띄울 화면(ADR 0063). 표시하는 순간에 부른다.
    /// `NSScreen.main`은 다른 앱의 창이어도 키보드 포커스가 있는 창의 화면이고 창 목록을 조회하지 않는다.
    /// 앱 전환 때 구해 둔 화면은 같은 앱의 다른 모니터 창으로 옮기면 낡으므로 그다음 후보다.
    static func focusedScreen(focused: NSScreen? = NSScreen.main, activeAppScreen: NSScreen?) -> NSScreen? {
        let screens = NSScreen.screens
        let index = ScreenGeometry.focusedScreenIndex(focusedScreen: focused?.frame, activeAppScreen: activeAppScreen?.frame,
                                                     screens: screens.map(\.frame))
        return index.map { screens[$0] }
    }

    private static func frontWindowBounds(pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // 목록은 앞(위)에서 뒤 순서다. 일반 윈도우 레이어(0)의 첫 항목이 최전면 윈도우.
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 1, rect.height > 1 else { continue }
            return rect
        }
        return nil
    }
}
