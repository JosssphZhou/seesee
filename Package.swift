// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "seesee",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "seesee", targets: ["seesee"])
    ],
    targets: [
        .executableTarget(
            name: "seesee",
            path: "Sources/seesee"
        )
    ],
    swiftLanguageVersions: [.v5]
)
