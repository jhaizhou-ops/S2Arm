import Foundation
import PackagePlugin

/// 共享规格（launchers/shared/experience.v1.json 体验规格、game_settings.v1.json 游戏设置定义表）拷进适配层资源包：
/// 源码资源目录不存副本或软链（坑记录：软链进资源包后失效）。
@main struct SharedExperienceResource: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let shared = context.package.directoryURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared")
        return ["experience.v1.json", "game_settings.v1.json"].map { name in
            let source = shared.appendingPathComponent(name)
            let resource = context.pluginWorkDirectoryURL.appendingPathComponent(name)
            return .buildCommand(displayName: "Copy shared specification \(name)", executable: URL(fileURLWithPath: "/bin/cp"),
                                 arguments: [source.path, resource.path], inputFiles: [source], outputFiles: [resource])
        }
    }
}
