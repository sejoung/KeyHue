// 막 실행된 앱에서 창 전환을 감지하는지 확인하는 도구(ADR 0033). Tests/perf/window-switch-after-launch.sh가 사용한다.
//
//   window-switch window         창 두 개를 띄우는 측정용 앱. KeyHuePerfWindows.app 번들로 실행되면 자동으로 이 모드다.
//   window-switch switch <pid>   그 앱의 두 창을 AX로 번갈아 앞으로 올린다(1초 간격 두 번). 앱을 활성화하지는 않는다.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
let isPerfApp = Bundle.main.bundleIdentifier?.hasPrefix("io.github.sejoung.keyhue.perf.") == true

if isPerfApp || arguments.dropFirst().first == "window" {
    final class Delegate: NSObject, NSApplicationDelegate {
        var windows: [NSWindow] = []
        func applicationDidFinishLaunching(_ notification: Notification) {
            for i in 0..<2 {
                let window = NSWindow(
                    contentRect: NSRect(x: 300 + i * 60, y: 300 + i * 60, width: 320, height: 120),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.title = "KeyHuePerfWindows \(i)"
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                windows.append(window)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

guard arguments.count >= 3, arguments[1] == "switch", let pid = pid_t(arguments[2]) else { exit(64) }
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("error: 이 터미널에 손쉬운 사용 권한이 필요합니다\n".data(using: .utf8)!)
    exit(1)
}
let app = AXUIElementCreateApplication(pid)
var value: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement], windows.count >= 2 else {
    FileHandle.standardError.write("error: 측정용 앱의 창 두 개를 찾지 못했습니다\n".data(using: .utf8)!)
    exit(1)
}
for window in [windows[1], windows[0]] {
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    RunLoop.current.run(until: Date().addingTimeInterval(1))
}
