// swift-tools-version: 6.2
// iCloud 存档同步的判定与云盘文件格式：iPhone / iPad 外壳和 Mac 启动器共用这一份，不依赖界面。
import PackageDescription

let package = Package(
    name: "SaveSync",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [.library(name: "SaveSync", targets: ["SaveSync"])],
    targets: [
        .target(name: "SaveSync"),
        .testTarget(name: "SaveSyncTests", dependencies: ["SaveSync"]),
    ]
)
