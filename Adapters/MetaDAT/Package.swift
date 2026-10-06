// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentWearLinkMetaDATIntegration",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
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
                .product(name: "MWDATMockDevice", package: "meta-wearables-dat-ios")
            ],
            path: "Sources"
        )
    ]
)
