// swift-tools-version: 6.2
// S2Arm iOS 游戏库界面包：ShellUI / ShellControllers 取自上游快照（见 UPSTREAM.md），S2ArmShellHost 是我方宿主层。
//   部署下限跟 tools/toolchain.env 的 IPHONEOS_DEPLOYMENT_TARGET（18.0）：上游声明 iOS 26，这里降到 18，
//   18 之后的 API 在源码里用 #available / canImport 门控（清单见 UPSTREAM.md「我方改动」）。
//   macOS 只给 swift test 在本机跑宿主层单测用（不出 Mac 产物），保留上游的 26。
import PackageDescription

let package = Package(
    name: "S2ArmShellUI",
    platforms: [.iOS(.v18), .macOS(.v26)],
    products: [
        .library(name: "ShellUI", targets: ["ShellUI"]),
        .library(name: "ShellControllers", targets: ["ShellControllers"]),
        // app.m 托管用的静态库：库界面 UIViewController 的 C 入口 + Play 回调（include/s2a_shell.h）
        .library(name: "S2ArmShellHost", type: .static, targets: ["S2ArmShellHost"])
    ],
    targets: [
        .target(name: "ShellUI", resources: [.process("Resources")]),
        .target(name: "ShellControllers", dependencies: ["ShellUI"]),
        // C 边界：Play 回调登记与转发（app.m / 宿主 C 侧只看这一个头文件）
        .target(name: "S2ArmShellBridge", path: "Sources/S2ArmShellBridge"),
        .target(name: "S2ArmShellHost", dependencies: ["ShellUI", "ShellControllers", "S2ArmShellBridge"]),
        .testTarget(name: "S2ArmShellHostTests", dependencies: ["S2ArmShellHost", "S2ArmShellBridge", "ShellUI"],
                    resources: [.copy("Fixtures")])
    ]
)
