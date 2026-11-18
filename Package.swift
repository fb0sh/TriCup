// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TriCup",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "TriCup", targets: ["TriCup"]),
        .executable(name: "TriCupHelper", targets: ["TriCupHelper"])
    ],
    targets: [
        .target(
            name: "TriCupCore",
            path: "Sources/TriCupCore"
        ),
        .executableTarget(
            name: "TriCup",
            dependencies: ["TriCupCore"],
            path: "Sources/TriCup"
        ),
        .executableTarget(
            name: "TriCupHelper",
            dependencies: ["TriCupCore"],
            path: "Sources/TriCupHelper"
        ),
        .testTarget(
            name: "TriCupTests",
            dependencies: ["TriCupCore"],
            path: "Tests/TriCupTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
