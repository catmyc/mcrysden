// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mcrysden",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mcrysden", targets: ["MolVisApp"]),
    ],
    targets: [
        .target(
            name: "MolEnvParse",
            path: "Sources/MolEnvParse",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fno-modules"]),
            ]
        ),
        .executableTarget(
            name: "MolVisApp",
            dependencies: ["MolEnvParse"],
            path: "Sources/MolVisApp",
            exclude: ["Shaders.metal"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "MolVisAppTests",
            dependencies: ["MolVisApp"],
            path: "Sources/MolVisAppTests"
        ),
    ]
)
