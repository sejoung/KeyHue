// 멈춘 앱에 대한 AX 요청이 얼마나 기다리는지 잰다(ADR 0030). Tests/perf/ax-timeout.sh가 사용한다.
//
//   stalled-app window              작은 창 하나를 띄우고 기다린다(측정 대상, 정지시켜 "멈춘 앱"을 흉내 낸다)
//   stalled-app probe <pid> <초|0>  대상 앱의 메인 창을 한 번 묻고 걸린 시간을 출력한다(0이면 시스템 기본값)
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "window":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.orderFront(nil)
    app.run()
case "probe":
    guard arguments.count == 4, let pid = pid_t(arguments[2]), let timeout = Float(arguments[3]) else { exit(64) }
    if timeout > 0 {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
    }
    var value: CFTypeRef?
    let start = Date()
    let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMainWindowAttribute as CFString, &value)
    print(String(format: "%.3f %d", Date().timeIntervalSince(start), error.rawValue))
default:
    FileHandle.standardError.write("usage: stalled-app window | probe <pid> <seconds|0>\n".data(using: .utf8)!)
    exit(64)
}
