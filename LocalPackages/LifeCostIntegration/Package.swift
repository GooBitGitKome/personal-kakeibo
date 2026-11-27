// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LifeCostIntegration", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "LifeCostIntegration", targets: ["LifeCostIntegration"])], targets: [.target(name: "LifeCostIntegration")])
