// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "visionmd",
    // Lower to .macOS(.v15) to build without native document-recognition tables
    // (RecognizeDocumentsRequest requires macOS 26; RecognizeTextRequest works on macOS 15)
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "visionmd",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "visionmdTests",
            dependencies: ["visionmd"]
        )
    ]
)
