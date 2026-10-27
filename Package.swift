// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MemoryNotes",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/jkrukowski/swift-embeddings", from: "0.1.1")],
    targets: [
        .executableTarget(name: "MemoryNotes", dependencies: [.product(name: "Embeddings", package: "swift-embeddings")]),
    ],
    swiftLanguageModes: [.v5]
)
