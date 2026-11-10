import Foundation

/// 游戏库结构 P3：玩家指定的库是入口，私有目录（~/Library/Application Support/S2Arm）只留设置、密钥和控制口文件。
/// 新旧前端算「日志 / 任务记录在哪」「缺省库放哪」都只调这里（后端同一规则在 pack/jobs/core.py logs_root、layout.py relocate_default）。
public enum S2ArmPaths {
    /// 前端缺省的私有目录；用 --data-root 指定了别的数据目录（测试、多开）时缺省库仍放在数据目录里，不写到玩家主目录。
    public static var standardPrivateRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("S2Arm")
    }

    /// 新装的缺省游戏库：~/S2Arm（访达里看得见）；自定义数据目录时是数据目录下的「游戏库」。
    public static func defaultLibrary(privateRoot: URL) -> URL {
        privateRoot.standardizedFileURL.path == standardPrivateRoot.standardizedFileURL.path
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("S2Arm", isDirectory: true)
            : privateRoot.appendingPathComponent("游戏库", isDirectory: true)
    }

    /// 设置里记的库路径，按后端搬库标记（<私有目录>/library-relocate.json，旧默认库同盘改名到 ~/S2Arm 时写）换成现在的位置：
    /// 记的是搬走前的旧路径、新位置有库标识、旧位置没有，就用新位置；其余原样。
    public static func library(privateRoot: URL, saved: String) -> String {
        guard !saved.isEmpty,
              let data = try? Data(contentsOf: privateRoot.appendingPathComponent("library-relocate.json")),
              let note = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let from = note["from"] as? String, let to = note["to"] as? String,
              URL(fileURLWithPath: from).standardizedFileURL.path == URL(fileURLWithPath: saved).standardizedFileURL.path else { return saved }
        let fm = FileManager.default
        guard fm.fileExists(atPath: URL(fileURLWithPath: to).appendingPathComponent(".s2arm-library.json").path),
              !fm.fileExists(atPath: URL(fileURLWithPath: saved).appendingPathComponent(".s2arm-library.json").path) else { return saved }
        return to
    }

    /// 设置文件 preferences.json 里的库路径（已按搬库标记换过）；没有就空串。
    public static func savedLibrary(privateRoot: URL) -> String {
        guard let data = try? Data(contentsOf: privateRoot.appendingPathComponent("preferences.json")),
              let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        return library(privateRoot: privateRoot, saved: p["library"] as? String ?? "")
    }

    /// 任务日志 + 任务记录（logs/jobs/）的目录：库建好了（有 .s2arm-library.json）是 <库>/logs，否则退回 <私有目录>/logs。
    /// library 不传就读设置文件。
    public static func logsRoot(privateRoot: URL, library: String? = nil) -> URL {
        let lib = library.map { Self.library(privateRoot: privateRoot, saved: $0) } ?? savedLibrary(privateRoot: privateRoot)
        if !lib.isEmpty {
            let root = URL(fileURLWithPath: lib, isDirectory: true)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(".s2arm-library.json").path) {
                return root.appendingPathComponent("logs")
            }
        }
        return privateRoot.appendingPathComponent("logs")
    }

    /// 任务记录目录 logs/jobs/。
    public static func jobsDir(privateRoot: URL, library: String? = nil) -> URL {
        logsRoot(privateRoot: privateRoot, library: library).appendingPathComponent("jobs")
    }
}
