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
        .target(
            name: "SpglibCore",
            path: "Sources/SpglibCore",
            exclude: ["spglib_f.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .unsafeFlags(["-fno-modules"]),
            ]
        ),
        .target(
            name: "MolEnvSpglib",
            dependencies: ["SpglibCore"],
            path: "Sources/MolEnvSpglib",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../SpglibCore"),
                .unsafeFlags(["-fno-modules"]),
            ]
        ),
        .target(
            name: "BandSurfaceRaster",
            path: "Sources/BandSurfaceRaster",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fno-modules"]),
            ]
        ),
        .executableTarget(
            name: "MolVisApp",
            dependencies: ["MolEnvParse", "MolEnvSpglib", "BandSurfaceRaster"],
            path: "Sources/MolVisApp",
            exclude: ["Shaders.metal"],
            resources: [.copy("Resources/SEEKPATH_LICENSE.txt")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "MolVisAppTests",
            dependencies: ["MolVisApp", "BandSurfaceRaster"],
            path: "Sources/MolVisAppTests",
            resources: [.process("Fixtures")]
        ),
    ]
)
