// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-auk: Tencent Hunyuan's AuK and AuK-Flash (mlx-auk-swift; the DiT and VAE are MIT, the required
// Qwen2.5-Omni-3B encoder is under the Qwen Research licence) as a Gaea plugin on MES Audio 0.1: speak, design a voice,
// edit speech and separate sources. One worker executable built on GaeaPluginKit, packaged as a signed .gaeaplugin by
// scripts/build-plugin.sh. Research use only: Gaea offers its models named-only and opt-in, with users' acceptance
// (G-27, AB-D-0209).
//
// auk-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution, requests and seeding, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-auk",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.11.0"),
        .package(url: "https://github.com/xocialize/mlx-auk-swift.git", exact: "0.3.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.74.1"),
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.74.1 takes it: 0.32.4 is upstream 0.32.3 plus the
        // _updateInternal leak fix (ml-explore/mlx-swift#501; AB-D-0208). AuK reloads its quantized encoder per request
        // when staged, which is what the leak killed. A root line naming ml-explore's URL would win and drop the fix.
        .package(url: "https://github.com/xocialize/mlx-swift", from: "0.32.4"),
    ],
    targets: [
        .target(
            name: "AuKPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXAuK", package: "mlx-auk-swift"),
                .product(name: "AuKCore", package: "mlx-auk-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-auk-worker",
            dependencies: [
                "AuKPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "auk-inproc",
            dependencies: [
                "AuKPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                .product(name: "MLXAuK", package: "mlx-auk-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "AuKPluginTests", dependencies: ["AuKPlugin"]),
    ]
)
