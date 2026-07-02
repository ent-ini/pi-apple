// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "apple-pi",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ApplePiCore",
            targets: ["ApplePiCore"]
        ),
        .library(
            name: "ApplePiRemote",
            targets: ["ApplePiRemote"]
        ),
        .executable(
            name: "ApplePi",
            targets: ["ApplePi"]
        ),
        .executable(
            name: "ApplePiIOS",
            targets: ["ApplePiIOS"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ApplePiCore",
            path: "Sources/ApplePiCore"
        ),
        .target(
            name: "ApplePiRemote",
            dependencies: ["ApplePiCore"],
            path: "Sources/ApplePiRemote"
        ),
        .executableTarget(
            name: "ApplePi",
            dependencies: ["ApplePiCore", "ApplePiRemote"],
            path: "Sources/ApplePi",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/ApplePi/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "ApplePiIOS",
            dependencies: ["ApplePiCore", "ApplePiRemote"],
            path: "Sources/ApplePiIOS"
        ),
        .testTarget(
            name: "ApplePiTests",
            dependencies: ["ApplePi", "ApplePiCore", "ApplePiRemote"],
            path: "Tests/ApplePiTests"
        )
    ]
)
