// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftPMConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "RiftExample",
            dependencies: [.product(name: "Rift", package: "rift")]
        )
    ]
)
