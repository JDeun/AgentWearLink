// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentWearLink",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentWearLinkCore", targets: ["AgentWearLinkCore"]),
        .library(name: "AgentWearLinkOpenClaw", targets: ["AgentWearLinkOpenClaw"])
    ],
    targets: [
        .target(name: "AgentWearLinkCore"),
        .target(
            name: "AgentWearLinkOpenClaw",
            dependencies: ["AgentWearLinkCore"]
        ),
        .testTarget(
            name: "AgentWearLinkCoreTests",
            dependencies: ["AgentWearLinkCore"]
        ),
        .testTarget(
            name: "AgentWearLinkOpenClawTests",
            dependencies: ["AgentWearLinkOpenClaw"]
        )
    ]
)
