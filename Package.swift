// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ANSdk",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ANSdk", targets: ["ANSdk"]),
    ],
    targets: [
        .target(name: "ANSdk", path: "Sources/ANSdk"),
    ]
)
