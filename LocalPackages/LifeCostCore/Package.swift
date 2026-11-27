// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LifeCostCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LifeCostDomain", targets: ["LifeCostDomain"])],
    dependencies: [.package(path: "../LifeCostIntegration")],
    targets: [
        .target(name: "LifeCostDomain", dependencies: [
            .product(name: "LifeCostIntegration", package: "LifeCostIntegration")
        ])
    ]
)
