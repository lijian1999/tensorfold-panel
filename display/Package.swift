// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TFPanel",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PanelCore"),
        .executableTarget(name: "TFPanel", dependencies: ["PanelCore"]),
        .testTarget(
            name: "PanelCoreTests",
            dependencies: ["PanelCore"],
            swiftSettings: [
                // 本机的 CLT 把 Testing 宏插件放在 plugins/testing 子目录，
                // swiftpm 的依赖扫描偶尔找不到它（工具链 bug），显式加进插件搜索路径
                .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])
            ]
        ),
    ]
)
