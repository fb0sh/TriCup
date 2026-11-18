// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TriCup",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "TriCup", targets: ["TriCup"])
    ],
    targets: [
        .target(
            name: "TriCupCore",
            path: "Sources/TriCupCore"
        ),
        .executableTarget(
            name: "TriCup",
            dependencies: ["TriCupCore"],
            path: "Sources/TriCup",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TriCupTests",
            dependencies: ["TriCupCore"],
            path: "Tests/TriCupTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
