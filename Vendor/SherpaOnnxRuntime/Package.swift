// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SherpaOnnxRuntime",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SherpaOnnxRuntime", targets: ["SherpaOnnxRuntime"])
    ],
    targets: [
        .binaryTarget(
            name: "sherpa-onnx",
            url: "https://github.com/willwade/sherpa-onnx-spm/releases/download/1.13.3/sherpa-onnx.xcframework.zip",
            checksum: "edf529802f437ff1d04057380fffb4151c092fc2cc71f00d17a01c2953887b6d"
        ),
        .binaryTarget(
            name: "onnxruntime",
            url: "https://github.com/willwade/sherpa-onnx-spm/releases/download/1.13.3/onnxruntime.xcframework.zip",
            checksum: "6d8fb92fab1c71be12d2f000df7ee4d29709be20aa9bd7f4d303bae10bd25415"
        ),
        .target(
            name: "SherpaOnnxRuntime",
            dependencies: ["sherpa-onnx", "onnxruntime"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate")
            ]
        )
    ]
)
