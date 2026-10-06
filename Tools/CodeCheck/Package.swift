// swift-tools-version: 6.0
import PackageDescription

// 저장소 Swift 코드의 구조 검사(ADR 0080). 앱 패키지가 swift-syntax에 의존하지 않도록 따로 둔다.
let package = Package(
    name: "CodeCheck",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")
    ],
    targets: [
        .target(
            name: "CodeCheckCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        ),
        .executableTarget(
            name: "code-check",
            dependencies: ["CodeCheckCore"]
        ),
        .testTarget(
            name: "CodeCheckCoreTests",
            dependencies: ["CodeCheckCore"]
        )
    ]
)
