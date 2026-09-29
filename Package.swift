// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyHue",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "KeyHue", targets: ["KeyHue"])
    ],
    targets: [
        // 순수 로직(상태 모델, 판정, 정책, 설정). AppKit/Carbon 의존 없음 → 단위 테스트 대상.
        .target(
            name: "KeyHueCore"
        ),
        // AppKit/Carbon 런타임: OS 이벤트 모니터, Overlay, 메뉴바 UI.
        .executableTarget(
            name: "KeyHue",
            dependencies: ["KeyHueCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "KeyHueCoreTests",
            dependencies: ["KeyHueCore"]
        )
    ]
)
