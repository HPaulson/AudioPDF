// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AudioPDF",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
        .executable(name: "AudioPDFApp", targets: ["AudioPDFApp"]),
        .executable(name: "VoiceVerification", targets: ["VoiceVerification"])
    ],
    dependencies: [
        .package(path: "Vendor/SherpaOnnxRuntime")
    ],
    targets: [
        .target(
            name: "ReaderCore",
            path: "AudioPDF/Core"
        ),
        .executableTarget(
            name: "AudioPDFApp",
            dependencies: [
                "ReaderCore",
                .product(name: "SherpaOnnxRuntime", package: "SherpaOnnxRuntime")
            ],
            path: "AudioPDF/App",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "VoiceVerification",
            dependencies: [
                .product(name: "SherpaOnnxRuntime", package: "SherpaOnnxRuntime")
            ],
            path: "VoiceVerification"
        ),
        .testTarget(
            name: "ReaderCoreTests",
            dependencies: ["ReaderCore"],
            path: "AudioPDFTests"
        )
    ]
)
