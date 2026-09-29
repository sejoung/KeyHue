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
