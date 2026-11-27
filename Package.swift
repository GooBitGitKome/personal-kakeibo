// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonalKakeibo",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PersonalKakeiboDomain", targets: ["PersonalKakeiboDomain"]),
        .library(name: "PersonalKakeiboApplication", targets: ["PersonalKakeiboApplication"])
    ],
    dependencies: [
        .package(path: "./LocalPackages/LifeCostIntegration")
    ],
    targets: [
        .target(name: "PersonalKakeiboDomain", dependencies: [.product(name: "LifeCostIntegration", package: "LifeCostIntegration")], path: "PersonalKakeibo/Domain"),
        .target(name: "PersonalKakeiboApplication", dependencies: [
            "PersonalKakeiboDomain",
            .product(name: "LifeCostIntegration", package: "LifeCostIntegration")
        ], path: "PersonalKakeibo/Application"),
        .testTarget(name: "PersonalKakeiboDomainTests", dependencies: ["PersonalKakeiboDomain"]),
        .testTarget(name: "PersistenceTests", dependencies: [
            "PersonalKakeiboDomain",
            "PersonalKakeiboApplication",
            .product(name: "LifeCostIntegration", package: "LifeCostIntegration")
        ], path: ".", sources: [
            "PersonalKakeibo/Infrastructure",
            "PersonalKakeibo/Presentation/KakeiboViewModel.swift",
            "PersonalKakeibo/Presentation/FinanceViewModel.swift",
            "PersonalKakeibo/Presentation/QuickExpenseViewModel.swift",
            "Tests/PersistenceTests"
        ])
    ]
)
