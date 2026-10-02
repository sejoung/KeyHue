// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyHue",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "KeyHue", targets: ["KeyHue"]),
        // ADR 0051: KeyHue.app에 내장하는 IMK 서비스 실행 파일. 별도 배포하지 않는다.
        .executable(name: "KeyHueInputMethodSpike", targets: ["KeyHueInputMethodSpike"])
    ],
    targets: [
        // 순수 로직(상태 모델, 판정, 정책, 설정, 자동 전환 조정). AppKit/Carbon 의존 없음 → 단위 테스트 대상.
        .target(
            name: "KeyHueCore"
        ),
        // AppKit/Carbon 런타임: OS 이벤트 모니터, Overlay, 메뉴바, 설정 창. 라이브러리라 통합 테스트에서 불러올 수 있다.
        .target(
            name: "KeyHueApp",
            dependencies: ["KeyHueCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        // 실행 파일: 진입점만 있다.
        .executableTarget(
            name: "KeyHue",
            dependencies: ["KeyHueApp"]
        ),
        .target(
            name: "KeyHueInputMethodSpikeCore",
            dependencies: ["KeyHueCore"],
            path: "Tools/InputMethodSpike/Core"
        ),
        .executableTarget(
            name: "KeyHueInputMethodSpike",
            dependencies: ["KeyHueInputMethodSpikeCore"],
            path: "Tools/InputMethodSpike/App",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "KeyHueInputMethodSpikeCoreTests",
            dependencies: ["KeyHueInputMethodSpikeCore"]
        ),
        .testTarget(
            name: "KeyHueCoreTests",
            dependencies: ["KeyHueCore"]
        ),
        // 실제 macOS API(화면, 입력 소스, 번역 번들, SwiftUI 모델)를 쓰는 통합 테스트.
        .testTarget(
            name: "KeyHueAppTests",
            dependencies: ["KeyHueApp", "KeyHueCore"]
        )
    ]
)
