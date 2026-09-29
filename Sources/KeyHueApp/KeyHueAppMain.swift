import AppKit

/// 앱 진입점. 실행 파일(`Sources/KeyHue/main.swift`)은 이것만 부른다.
/// 앱 코드를 라이브러리(KeyHueApp)로 두어야 테스트(KeyHueAppTests)에서 불러올 수 있다(ADR 0022).
@MainActor
public enum KeyHueAppMain {
    public static func run() -> Never {
        let app = NSApplication.shared

        // 매뉴얼용 스크린샷 모드(scripts/screenshots.sh). Dock에 나타나지 않게 하고 이미지만 만든 뒤 끝낸다.
        if CommandLine.arguments.contains(DocScreenshots.flag) {
            app.setActivationPolicy(.accessory)
            _ = DocScreenshots.runIfRequested()
            exit(0)
        }

        // Dock 표시 여부(설정)는 AppDelegate.applicationWillFinishLaunching에서 적용한다.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }
}
