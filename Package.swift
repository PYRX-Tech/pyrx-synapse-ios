// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PYRXSynapse",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v7),
    ],
    products: [
        .library(
            name: "PYRXSynapse",
            targets: ["PYRXSynapse"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PYRXSynapse",
            dependencies: [],
            path: "Sources/PYRXSynapse"
        ),
        .testTarget(
            name: "PYRXSynapseTests",
            dependencies: ["PYRXSynapse"],
            path: "Tests/PYRXSynapseTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
