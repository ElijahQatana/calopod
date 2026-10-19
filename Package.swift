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
        .library(name: "CalopodEventKit", targets: ["CalopodEventKit"]),
        .library(name: "CalopodMicrosoft", targets: ["CalopodMicrosoft"]),
        .library(name: "CalopodStore", targets: ["CalopodStore"]),
        .library(name: "CalopodSync", targets: ["CalopodSync"]),
        .library(name: "CalopodSnapshot", targets: ["CalopodSnapshot"]),
        .library(name: "CalopodRuntime", targets: ["CalopodRuntime"]),
        .executable(name: "calopod", targets: ["CalopodCLI"]),
        .executable(name: "calopod-agent", targets: ["CalopodAgent"]),
        .executable(name: "calopod-mac", targets: ["CalopodMac"]),
        .executable(name: "calopod-eventkit-host", targets: ["CalopodEventKitHost"]),
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
            name: "CalopodSnapshot",
            dependencies: ["CalopodDomain"]
        ),
        .target(
            name: "CalopodSync",
            dependencies: ["CalopodDomain", "CalopodProviders", "CalopodStore"]
        ),
        .target(
            name: "CalopodRuntime",
            dependencies: [
                "CalopodDomain",
                "CalopodEventKit",
                "CalopodGoogle",
                "CalopodMicrosoft",
                "CalopodProviders",
                "CalopodStore",
                "CalopodSync",
            ]
        ),
        .target(
            name: "CalopodGoogle",
            dependencies: ["CalopodDomain", "CalopodProviders", "CalopodStore"]
        ),
        .target(
            name: "CalopodEventKit",
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
                "CalopodEventKit",
                "CalopodGoogle",
                "CalopodMicrosoft",
                "CalopodProviders",
                "CalopodRuntime",
                "CalopodSnapshot",
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
            name: "CalopodMac",
            dependencies: ["CalopodCommands", "CalopodEventKit", "CalopodRuntime", "CalopodSnapshot"]
        ),
        .executableTarget(
            name: "CalopodAgent",
            dependencies: ["CalopodRuntime"]
        ),
        .executableTarget(
            name: "CalopodEventKitHost",
            dependencies: ["CalopodEventKit", "CalopodProviders"]
        ),
        .target(
            name: "CalopodTestSupport",
            dependencies: ["CalopodDomain", "CalopodStore"],
            path: "Tests/Support"
        ),
        .testTarget(
            name: "CalopodMacTests",
            dependencies: ["CalopodMac"]
        ),
        .testTarget(
            name: "CalopodDomainTests",
            dependencies: ["CalopodDomain", "CalopodTestSupport"]
        ),
        .testTarget(
            name: "CalopodSnapshotTests",
            dependencies: ["CalopodDomain", "CalopodSnapshot"]
        ),
        .testTarget(
            name: "CalopodSyncTests",
            dependencies: [
                "CalopodDomain",
                "CalopodProviders",
                "CalopodStore",
                "CalopodSync",
                "CalopodTestSupport",
            ]
        ),
        .testTarget(
            name: "CalopodStoreTests",
            dependencies: ["CalopodDomain", "CalopodStore", "CalopodTestSupport"]
        ),
        .testTarget(
            name: "CalopodProvidersTests",
            dependencies: ["CalopodProviders"]
        ),
        .testTarget(
            name: "CalopodRuntimeTests",
            dependencies: [
                "CalopodDomain",
                "CalopodProviders",
                "CalopodRuntime",
                "CalopodStore",
            ]
        ),
        .testTarget(
            name: "CalopodCommandsTests",
            dependencies: ["CalopodCommands", "CalopodSnapshot", "CalopodStore", "CalopodTestSupport"]
        ),
        .testTarget(
            name: "CalopodGoogleTests",
            dependencies: ["CalopodGoogle", "CalopodProviders", "CalopodStore"]
        ),
        .testTarget(
            name: "CalopodEventKitTests",
            dependencies: [
                "CalopodDomain",
                "CalopodEventKit",
                "CalopodGoogle",
                "CalopodMicrosoft",
                "CalopodProviders",
                "CalopodStore",
                "CalopodSync",
            ]
        ),
        .testTarget(
            name: "CalopodMicrosoftTests",
            dependencies: ["CalopodMicrosoft", "CalopodProviders", "CalopodStore"]
        ),
    ]
)
