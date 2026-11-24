// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BLEDiscoveryPolicy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ProbePolicy", targets: ["ProbePolicy"])],
    targets: [.target(name: "ProbePolicy"),
              .testTarget(name: "ProbePolicyTests", dependencies: ["ProbePolicy"])]
)
