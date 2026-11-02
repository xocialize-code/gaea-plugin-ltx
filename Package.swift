// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-ltx: Lightricks' LTX 2.5 distilled (weights under the LTX-2 Community License) as a Gaea plugin on MES
// Video 0.1's video.generate, video.extend and video.retake. One worker executable built on GaeaPluginKit over
// ltx-2-mlx-swift, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// ltx-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution and requests, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-ltx",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.9.1"),
        .package(url: "https://github.com/xocialize/ltx-2-mlx-swift.git", exact: "0.20.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.73.1"),
    ],
    targets: [
        .target(
            name: "LTXPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXLTX2", package: "ltx-2-mlx-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-ltx-worker",
            dependencies: [
                "LTXPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "ltx-inproc",
            dependencies: [
                "LTXPlugin",
                .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                .product(name: "MLXLTX2", package: "ltx-2-mlx-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LTXPluginTests",
                    dependencies: ["LTXPlugin", .product(name: "MLXLTX2", package: "ltx-2-mlx-swift")]),
    ]
)
