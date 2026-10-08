// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentWearLinkMetaDATIntegration",
    platforms: [
        .iOS("17.2")
    ],
    products: [
        .library(
            name: "AgentWearLinkMetaDATIntegration",
            targets: ["AgentWearLinkMetaDATIntegration"]
        ),
        .library(
            name: "AgentWearLinkMetaDATTestSupport",
            targets: ["AgentWearLinkMetaDATTestSupport"]
        )
    ],
    dependencies: [
        .package(path: "../.."),
        .package(
            url: "https://github.com/facebook/meta-wearables-dat-ios",
            revision: "1f38beecba83c4c8b5e343540f9cd615323ab19a"
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
                .product(name: "MWDATSpeech", package: "meta-wearables-dat-ios")
            ],
            path: "Sources"
        ),
        .target(
            name: "AgentWearLinkMetaDATTestSupport",
            dependencies: [
                "AgentWearLinkMetaDATIntegration",
                .product(name: "MWDATCore", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATMockDevice", package: "meta-wearables-dat-ios")
            ],
            path: "TestSupport",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "AgentWearLinkMetaDATIntegrationTests",
            dependencies: [
                "AgentWearLinkMetaDATIntegration",
                "AgentWearLinkMetaDATTestSupport",
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
    ],
    // The vendor SDK requires a Swift 6-capable package manager, while the
    // integration sources remain in Swift 5 language mode during migration.
    swiftLanguageModes: [.v5]
)
