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
        .library(name: "CalopodStore", targets: ["CalopodStore"]),
        .library(name: "CalopodSync", targets: ["CalopodSync"]),
        .executable(name: "calopod", targets: ["CalopodCLI"]),
        .executable(name: "calopod-agent", targets: ["CalopodAgent"]),
    ],
    targets: [
        .target(name: "CalopodDomain"),
        .target(name: "CalopodProviders", dependencies: ["CalopodDomain"]),
        .target(name: "CalopodStore", dependencies: ["CalopodDomain"]),
        .target(
            name: "CalopodSync",
            dependencies: ["CalopodDomain", "CalopodProviders", "CalopodStore"]
        ),
        .executableTarget(
            name: "CalopodCLI",
            dependencies: ["CalopodDomain", "CalopodSync"]
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
    ]
)
