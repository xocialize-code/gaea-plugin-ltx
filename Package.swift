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
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.14.1"), // 0.14.1 on: the manifest names the engine actually linked (MLXEngineRelease)
        .package(url: "https://github.com/xocialize/ltx-2-mlx-swift.git", exact: "0.23.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.82.1"),
        // ltx-inproc reads MLX's memory counters. The fleet's mlx-swift fork, as mlx-engine-swift 0.82.1 takes it: 0.33.1 is upstream 0.33.0 with the vendored
        // MLX's head-dim-split SDPA routes off, which abort or give wrong attention on M5 (AB-D-0264, AB-R-1009). It
        // replaces the 0.32.4 leak-fix fork (AB-D-0208), whose fix upstream 0.33.0 carries. A root line naming
        // ml-explore's URL would win and drop the patch.
        .package(url: "https://github.com/xocialize/mlx-swift", from: "0.33.1"),
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
                .product(name: "MLX", package: "mlx-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LTXPluginTests",
                    dependencies: ["LTXPlugin", .product(name: "MLXLTX2", package: "ltx-2-mlx-swift")]),
    ]
)
