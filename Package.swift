// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MemoryNotes",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/jkrukowski/swift-embeddings", from: "0.1.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "MemoryNotes",
            dependencies: [.product(name: "Embeddings", package: "swift-embeddings"), .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]  // finds the embedded Sparkle.framework
        ),
        .testTarget(name: "MemoryNotesTests", dependencies: ["MemoryNotes"]),
    ],
    swiftLanguageModes: [.v5]
)
