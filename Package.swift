// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "apfel-run",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "apfel-run", targets: ["apfel-run"]),
        .library(name: "ApfelRunCore", targets: ["ApfelRunCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "ApfelRunCore",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/ApfelRunCore"
        ),
        .executableTarget(
            name: "apfel-run",
            dependencies: ["ApfelRunCore"],
            path: "Sources/apfel-run"
        ),
        .testTarget(
            name: "ApfelRunCoreTests",
            dependencies: ["ApfelRunCore"],
            path: "Tests/ApfelRunCoreTests"
        ),
    ]
)
