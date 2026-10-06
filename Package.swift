// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentWearLink",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentWearLinkCore", targets: ["AgentWearLinkCore"])
    ],
    targets: [
        .target(name: "AgentWearLinkCore"),
        .testTarget(
            name: "AgentWearLinkCoreTests",
            dependencies: ["AgentWearLinkCore"]
        )
    ]
)
