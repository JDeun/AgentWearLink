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
        .library(name: "AgentWearLinkOpenClaw", targets: ["AgentWearLinkOpenClaw"]),
        .library(name: "AgentWearLinkMetaDAT", targets: ["AgentWearLinkMetaDAT"]),
        .library(name: "AgentWearLinkAppleOutput", targets: ["AgentWearLinkAppleOutput"]),
        .executable(name: "awl-openclaw-probe", targets: ["AgentWearLinkOpenClawProbe"]),
        .executable(name: "awl-openclaw-chat-probe", targets: ["AgentWearLinkOpenClawChatProbe"])
    ],
    targets: [
        .target(name: "AgentWearLinkCore"),
        .target(
            name: "AgentWearLinkMetaDAT",
            dependencies: ["AgentWearLinkCore"]
        ),
        .target(
            name: "AgentWearLinkAppleOutput",
            dependencies: ["AgentWearLinkCore"]
        ),
        .target(
            name: "AgentWearLinkOpenClaw",
            dependencies: ["AgentWearLinkCore"]
        ),
        .executableTarget(
            name: "AgentWearLinkOpenClawProbe",
            dependencies: ["AgentWearLinkOpenClaw"]
        ),
        .executableTarget(
            name: "AgentWearLinkOpenClawChatProbe",
            dependencies: ["AgentWearLinkOpenClaw", "AgentWearLinkCore"]
        ),
        .testTarget(
            name: "AgentWearLinkAppleOutputTests",
            dependencies: ["AgentWearLinkAppleOutput", "AgentWearLinkCore"]
        ),
        .testTarget(
            name: "AgentWearLinkMetaDATTests",
            dependencies: ["AgentWearLinkMetaDAT", "AgentWearLinkCore"]
        ),
        .testTarget(
            name: "AgentWearLinkCoreTests",
            dependencies: ["AgentWearLinkCore"]
        ),
        .testTarget(
            name: "AgentWearLinkOpenClawTests",
            dependencies: ["AgentWearLinkOpenClaw", "AgentWearLinkCore"]
        )
    ]
)
