// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FieldLog",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FieldLogModels", targets: ["FieldLogModels"]), .library(name: "FieldLogStorage", targets: ["FieldLogStorage"])],
    targets: [
        .target(name: "FieldLogModels"),
        .target(name: "FieldLogStorage", dependencies: ["FieldLogModels"]),
        .testTarget(name: "FieldLogTests", dependencies: ["FieldLogModels", "FieldLogStorage"])
    ]
)
