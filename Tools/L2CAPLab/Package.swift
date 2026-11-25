// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "L2CAPLab",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LabTransport", targets: ["LabTransport"])],
    targets: [
        .target(name: "LabTransport"),
        .testTarget(name: "LabTransportTests", dependencies: ["LabTransport"])
    ]
)
