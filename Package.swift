// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rift",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Rift", targets: ["Rift"])],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.5")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CRiftFilesystem", publicHeadersPath: "include"),
        .target(
            name: "Rift",
            dependencies: [
                "CSQLite", "CRiftFilesystem",
                .product(name: "TOMLDecoder", package: "TOMLDecoder")
            ]
        ),
        .testTarget(name: "RiftTests", dependencies: ["Rift", "CSQLite", "CRiftFilesystem"])
    ],
    cLanguageStandard: .c11
)
