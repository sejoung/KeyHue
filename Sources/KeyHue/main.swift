import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Info.plist의 LSUIElement와 동일. `swift run`처럼 번들 없이 실행해도 Dock에 나타나지 않게 한다.
app.setActivationPolicy(.accessory)
app.run()
