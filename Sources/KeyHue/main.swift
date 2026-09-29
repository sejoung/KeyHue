import AppKit

let app = NSApplication.shared
// Info.plist의 LSUIElement와 동일. `swift run`처럼 번들 없이 실행해도 Dock에 나타나지 않게 한다.
app.setActivationPolicy(.accessory)

// 매뉴얼용 스크린샷 모드(scripts/screenshots.sh). 앱을 띄우지 않고 이미지만 만들고 끝낸다.
if DocScreenshots.runIfRequested() {
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
