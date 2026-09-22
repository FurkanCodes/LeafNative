// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LeafNative",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Leaf", targets: ["LeafNative"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        )
    ],
    targets: [
        .executableTarget(
            name: "LeafNative",
            dependencies: ["ZIPFoundation"],
            path: "Sources/LeafNative"
        ),
        .testTarget(
            name: "LeafNativeTests",
            dependencies: ["LeafNative", "ZIPFoundation"],
            path: "Tests/LeafNativeTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
