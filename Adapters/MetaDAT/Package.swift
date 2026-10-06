// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentWearLinkMetaDATIntegration",
    platforms: [
        .iOS("17.2"),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AgentWearLinkMetaDATIntegration",
            targets: ["AgentWearLinkMetaDATIntegration"]
        ),
        .executable(
            name: "AgentWearLinkMetaDATTestHost",
            targets: ["AgentWearLinkMetaDATTestHost"]
        )
    ],
    dependencies: [
        .package(path: "../.."),
        .package(
            url: "https://github.com/facebook/meta-wearables-dat-ios",
            exact: "1.0.0"
        )
    ],
    targets: [
        .target(
            name: "AgentWearLinkMetaDATIntegration",
            dependencies: [
                .product(name: "AgentWearLinkCore", package: "AgentWearLink"),
                .product(name: "AgentWearLinkMetaDAT", package: "AgentWearLink"),
                .product(name: "MWDATCore", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATCamera", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATSpeech", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATMockDevice", package: "meta-wearables-dat-ios")
            ],
            path: "Sources"
        ),
        .executableTarget(
            name: "AgentWearLinkMetaDATTestHost",
            dependencies: ["AgentWearLinkMetaDATIntegration"],
            path: "TestHost"
        ),
        .testTarget(
            name: "AgentWearLinkMetaDATIntegrationTests",
            dependencies: [
                "AgentWearLinkMetaDATIntegration",
                .product(name: "MWDATMockDevice", package: "meta-wearables-dat-ios")
            ],
            path: "Tests"
        ),
        .testTarget(
            name: "AgentWearLinkMetaDATMockDeviceUITests",
            dependencies: [
                "AgentWearLinkMetaDATIntegration",
                .product(name: "MWDATMockDeviceTestClient", package: "meta-wearables-dat-ios")
            ],
            path: "UITests"
        )
    ]
)
