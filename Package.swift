// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ANSdk",
    platforms: [
        .iOS(.v15),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ANSdk", targets: ["ANSdk"]),
    ],
    dependencies: [
        // ONNX Runtime via Microsoft's official SPM wrapper. Pinned exact —
        // bumping requires regenerating goldens (model behavior can drift
        // across ORT versions, especially around NMS/quantization paths).
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            exact: "1.24.2"
        ),
    ],
    targets: [
        .target(
            name: "ANSdk",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/ANSdk",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "ANSdkGoldenCheck",
            dependencies: ["ANSdk"],
            path: "Sources/ANSdkGoldenCheck"
        ),
    ]
)
