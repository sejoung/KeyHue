// macOS 입력 소스 표시(커서 옆 한/A 배지)를 캡처로 확인하는 도구(ADR 0034). Tests/perf/input-indicator.sh가 사용한다.
//
//   input-indicator window                 텍스트 뷰 하나인 측정용 앱. KeyHuePerfIndicator.app 번들로 실행되면 자동으로 이 모드다.
//   input-indicator shoot <접두사> <회수>   측정용 앱이 맨 앞일 때 입력 소스를 바꾸고 150 ms 뒤 **그 창만** 캡처한다.
//                                          출력: "<파일> <배지 픽셀 수>". 맨 앞 앱이 바뀌면 멈춘다(다른 앱 화면을 찍지 않는다).
import AppKit
import Carbon

let perfID = "io.github.sejoung.keyhue.perf.indicator"
let arguments = CommandLine.arguments

if Bundle.main.bundleIdentifier == perfID || arguments.dropFirst().first == "window" {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 400, y: 400, width: 360, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "KeyHuePerfIndicator"
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
    // 배지는 커서 왼쪽 아래에 뜬다. 커서를 안쪽으로 들여 배지가 창 안(흰 배경)에 오게 한다.
    textView.textContainerInset = NSSize(width: 80, height: 30)
    window.contentView = textView
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textView)
    app.activate(ignoringOtherApps: true)
    app.run()
}

guard arguments.count >= 4, arguments[1] == "shoot" else { exit(64) }
let prefix = arguments[2]
let count = Int(arguments[3]) ?? 2

func spin(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func perfIsFront() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == perfID }
func source(_ id: String) -> TISInputSource? {
    (TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource])?.first
}
func currentID() -> String {
    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    return Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(current, kTISPropertyInputSourceID)).takeUnretainedValue() as String
}

/// 배지의 파란색 픽셀 수. 커서(가는 파란 선)도 조금 잡히므로 판정은 스크립트에서 기준값으로 한다.
func badgePixels(_ path: String) -> Int {
    guard let data = FileManager.default.contents(atPath: path), let image = NSBitmapImageRep(data: data) else { return -1 }
    var n = 0
    for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.blueComponent > 0.78, c.redComponent < 0.25, c.greenComponent > 0.3, c.greenComponent < 0.67 { n += 1 }
        }
    }
    return n
}

var waited = 0.0
while !perfIsFront() && waited < 3 { spin(0.1); waited += 0.1 }
guard perfIsFront(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
    print("error: 측정용 앱이 맨 앞에 오지 않았습니다(지금 맨 앞: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))")
    exit(2)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
guard let info = list.first(where: {
          ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
      }),
      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
    print("error: 측정용 앱의 창을 찾지 못했습니다")
    exit(1)
}

let ids = ["com.apple.inputmethod.Korean.2SetKorean", "com.apple.keylayout.ABC"]
let original = currentID()
spin(0.3)
for i in 0..<count {
    guard perfIsFront() else { print("error: 측정 중 맨 앞 앱이 바뀌었습니다"); exit(3) }
    // 지금과 다른 입력 소스로 바꿔야 배지가 뜬다.
    let target = currentID() == ids[0] ? ids[1] : ids[0]
    guard let next = source(target) else { print("error: \(target)이 켜져 있지 않습니다"); exit(1) }
    TISSelectInputSource(next)
    spin(0.15)
    let file = "\(prefix)-\(i + 1).png"
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-R", "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))", file]
    try capture.run()
    capture.waitUntilExit()
    print("\(file) \(badgePixels(file))")
    spin(1.2) // 배지가 사라질 때까지
}
if let back = source(original) { TISSelectInputSource(back) }
