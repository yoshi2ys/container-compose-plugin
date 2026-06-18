// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "container-compose",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ComposeModel", targets: ["ComposeModel"]),
        .library(name: "ComposeGraph", targets: ["ComposeGraph"]),
        .library(name: "ComposeTranslate", targets: ["ComposeTranslate"]),
        .library(name: "ContainerEngine", targets: ["ContainerEngine"]),
        .executable(name: "compose", targets: ["compose"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .target(
            name: "ComposeModel",
            dependencies: [.product(name: "Yams", package: "Yams")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ComposeModelTests",
            dependencies: ["ComposeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ComposeGraph",
            dependencies: ["ComposeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ComposeGraphTests",
            dependencies: ["ComposeGraph", "ComposeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ComposeTranslate",
            dependencies: ["ComposeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ComposeTranslateTests",
            dependencies: ["ComposeTranslate", "ComposeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ContainerEngine",
            dependencies: ["ComposeModel", "ComposeGraph", "ComposeTranslate"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ContainerEngineTests",
            dependencies: ["ContainerEngine", "ComposeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "compose",
            dependencies: ["ComposeModel", "ComposeTranslate", "ContainerEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
