// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Calopod",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "CalopodDomain", targets: ["CalopodDomain"]),
        .library(name: "CalopodProviders", targets: ["CalopodProviders"]),
        .library(name: "CalopodGoogle", targets: ["CalopodGoogle"]),
        .library(name: "CalopodMicrosoft", targets: ["CalopodMicrosoft"]),
        .library(name: "CalopodStore", targets: ["CalopodStore"]),
        .library(name: "CalopodSync", targets: ["CalopodSync"]),
        .executable(name: "calopod", targets: ["CalopodCLI"]),
        .executable(name: "calopod-agent", targets: ["CalopodAgent"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.10.0"
        ),
    ],
    targets: [
        .target(name: "CalopodDomain"),
        .target(
            name: "CalopodProviders",
            dependencies: ["CalopodDomain", "CalopodStore"]
        ),
        .target(
            name: "CalopodStore",
            dependencies: [
                "CalopodDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "CalopodSync",
            dependencies: ["CalopodDomain", "CalopodProviders", "CalopodStore"]
        ),
        .target(
            name: "CalopodGoogle",
            dependencies: ["CalopodDomain", "CalopodProviders", "CalopodStore"]
        ),
        .target(
            name: "CalopodMicrosoft",
            dependencies: ["CalopodDomain", "CalopodProviders", "CalopodStore"]
        ),
        .target(
            name: "CalopodCommands",
            dependencies: [
                "CalopodDomain",
                "CalopodGoogle",
                "CalopodMicrosoft",
                "CalopodProviders",
                "CalopodStore",
                "CalopodSync",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "CalopodCLI",
            dependencies: ["CalopodCommands"]
        ),
        .executableTarget(
            name: "CalopodAgent",
            dependencies: ["CalopodDomain", "CalopodSync"]
        ),
        .target(
            name: "CalopodTestSupport",
            dependencies: ["CalopodDomain"],
            path: "Tests/Support"
        ),
        .testTarget(
            name: "CalopodDomainTests",
            dependencies: ["CalopodDomain", "CalopodTestSupport"]
        ),
        .testTarget(
            name: "CalopodSyncTests",
            dependencies: ["CalopodDomain", "CalopodSync", "CalopodTestSupport"]
        ),
        .testTarget(
            name: "CalopodStoreTests",
            dependencies: ["CalopodDomain", "CalopodStore"]
        ),
        .testTarget(
            name: "CalopodCommandsTests",
            dependencies: ["CalopodCommands", "CalopodStore"]
        ),
        .testTarget(
            name: "CalopodGoogleTests",
            dependencies: ["CalopodGoogle", "CalopodProviders", "CalopodStore"]
        ),
        .testTarget(
            name: "CalopodMicrosoftTests",
            dependencies: ["CalopodMicrosoft", "CalopodProviders", "CalopodStore"]
        ),
    ]
)
