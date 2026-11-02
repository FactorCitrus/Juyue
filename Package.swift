// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Juyue",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "JuyueCore",
            targets: ["JuyueCore"]),
        .library(
            name: "JuyueApp",
            targets: ["JuyueApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.16")
    ],
    targets: [
        .target(
            name: "JuyueCore",
            dependencies: [
                "SwiftSoup",
                "ZIPFoundation"
            ]),
        .target(
            name: "JuyueApp",
            dependencies: [
                "JuyueCore"
            ],
            exclude: ["Info.plist", "Info-AppStore.plist"],
            resources: [
                .process("Resources"),
                .copy("PrivacyInfo.xcprivacy")
            ]),
        .testTarget(
            name: "JuyueCoreTests",
            dependencies: ["JuyueCore"]),
    ]
)
