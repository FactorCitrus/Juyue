// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Legado",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "LegadoCore",
            targets: ["LegadoCore"]),
        .library(
            name: "LegadoApp",
            targets: ["LegadoApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.16")
    ],
    targets: [
        .target(
            name: "LegadoCore",
            dependencies: [
                "SwiftSoup",
                "ZIPFoundation"
            ]),
        .target(
            name: "LegadoApp",
            dependencies: [
                "LegadoCore"
            ],
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ]),
        .testTarget(
            name: "LegadoCoreTests",
            dependencies: ["LegadoCore"]),
    ]
)
