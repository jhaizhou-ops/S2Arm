import Foundation

// NX2Apple 启动器的引擎接口（作者设计稿 2.13「Launcher boundary and multi-engine support」，事件格式 2.14 nxevents）。
// 对方还没把协议落进他们的 NXCore：这里按设计稿逐字段定义同名协议，S2Arm 实现它（S2ArmEngineProvider）。
// 对方协议落地 NXCore 后改为引用它：删掉本文件的同名类型，S2ArmEngineProvider 改成遵循对方的协议，字段差异在那时对齐。

/// 引擎标识（设计稿："the reference port"、"nxrust"，以后别的引擎）。S2Arm 是 "s2arm"。
public struct EngineID: RawRepresentable, Hashable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// 出包目标。
public enum EngineTarget: String, CaseIterable {
    /// 本机运行（Mac 上的运行文件）。
    case mac = "macos-arm64"
    /// iPhone / iPad 安装包（IPA + 资源包）。
    case iPhone = "ios-arm64"
}

/// 引擎能力（设计稿：targets、Switch 2、120 fps、render scale、cheats、cloud saves、runtime shaders）。
/// widescreen / fps60 是 S2Arm 加的两项（引擎有这类能力；按款缺省开、匹配不到自动不用，不给玩家开关）。
public struct EngineCapabilities: Equatable {
    public var targets: [EngineTarget]
    public var switch2: Bool
    public var fps120: Bool
    public var renderScale: Bool
    public var cheats: Bool
    public var cloudSaves: Bool
    public var runtimeShaders: Bool
    public var widescreen: Bool
    public var fps60: Bool

    public init(targets: [EngineTarget], switch2: Bool = false, fps120: Bool = false, renderScale: Bool = false, cheats: Bool = false,
                cloudSaves: Bool = false, runtimeShaders: Bool = false, widescreen: Bool = false, fps60: Bool = false) {
        self.targets = targets; self.switch2 = switch2; self.fps120 = fps120; self.renderScale = renderScale; self.cheats = cheats
        self.cloudSaves = cloudSaves; self.runtimeShaders = runtimeShaders; self.widescreen = widescreen; self.fps60 = fps60
    }
}

/// inspect 的输入：玩家拖进来 / 选的文件或文件夹（NSP / XCI / 装着它们的文件夹）。
public struct GameInputs: Equatable {
    public var paths: [URL]
    public init(paths: [URL]) { self.paths = paths }
}

/// 一款游戏（设计稿：title id、version、profile state）。
public struct GameInfo: Equatable {
    /// 设计稿 profile state：committed = 引擎对这款有定稿配置；provisional = 还在试。
    public enum ProfileState: String { case committed, provisional }
    public let titleId: String
    public let name: String
    public let version: String
    public let profileState: ProfileState
    /// S2Arm 游戏库里的这一项（运行文件状态、封面、缺什么）。
    public let summary: GameSummary

    public init(summary: GameSummary) {
        self.summary = summary
        titleId = summary.id; name = summary.name; version = summary.display
        // S2Arm 目前没有「定稿配置」：作业层 catalog 只给 experimental / unsupported，一律 provisional
        profileState = .provisional
    }
}

/// build 的输入。
public struct BuildJob {
    public var gameId: String
    public var target: EngineTarget
    /// iPhone：目标设备（targetDevice 作业给的那一项，原样转给 ipa 作业的 target 字段，只用来提示地址窗口）；没有不带。直连包一包通用。
    public var deviceTarget: [String: Any]?
    /// 空间预检没过时玩家选了「仍然继续」。
    public var spaceOverride = false
    /// 出包页选的存放位置（游戏库结构 v3）：这款放到哪个文件夹；在别的位置就先整个搬过去。nil = 不动
    public var location: String?

    public init(gameId: String, target: EngineTarget, deviceTarget: [String: Any]? = nil, spaceOverride: Bool = false, location: String? = nil) {
        self.gameId = gameId; self.target = target; self.deviceTarget = deviceTarget; self.spaceOverride = spaceOverride; self.location = location
    }
}

/// build 的结果。
public struct BuildResult {
    public let gameId: String
    public let target: EngineTarget
    /// Mac：运行文件目录；iPhone：IPA 与资源包所在文件夹。
    public let outputPath: String?
    /// iPhone：IPA 文件。
    public let ipa: String?
    /// 作业层结果原样（buildId、compilerCache 等）。
    public let raw: [String: Any]
}

/// 事件（设计稿 2.14：一份 NDJSON schema 管出包与运行，`{ev, t, code, severity, fields}`）。
public struct EngineEvent {
    public enum Severity: String { case info, warning, error }
    /// 事件类型：作业层的 type（stage / progress / log / check / heartbeat / result）。
    public let ev: String
    /// 作业开始后的秒数（作业层 elapsed）。
    public let t: Double
    /// 恢复码（失败诊断 / 检查项的 code；没有为 nil）。
    public let code: String?
    public let severity: Severity
    /// 作业层这一行原样（schema 1）。
    public let fields: [String: Any]

    public init(ev: String, t: Double, code: String?, severity: Severity, fields: [String: Any]) {
        self.ev = ev; self.t = t; self.code = code; self.severity = severity; self.fields = fields
    }

    public var message: String { fields["message"] as? String ?? "" }
    public var stage: String? { fields["stage"] as? String }
    public var isFinal: Bool { ev == "result" }

    /// 作业层的一行事件。
    public init(job e: JobEvent) {
        let diagnostics = e.fields["diagnostics"] as? [[String: Any]] ?? []
        let check = e.fields["check"] as? [String: Any]
        let code = e.fields["code"] as? String ?? diagnostics.first?["code"] as? String
            ?? (check?["diagnostic"] as? [String: Any])?["code"] as? String
        let severity: Severity
        switch (e.type, e.state) {
        case ("result", "failed"), ("result", "interrupted"): severity = .error
        case ("check", _): severity = check?["ok"] as? Bool == false ? .warning : .info
        default: severity = .info
        }
        self.init(ev: e.type, t: (e.fields["elapsed"] as? NSNumber)?.doubleValue ?? 0, code: code, severity: severity, fields: e.fields)
    }

    /// 作业的结局（每个作业恰好一条，最后一条）：作业层的结果事件，或进程中途没了时由适配层补的那条。
    public init(outcome o: JobOutcome) {
        let severity: Severity = (o.state == .failed || o.state == .interrupted) ? .error : .info
        var fields: [String: Any] = ["schema": 1, "taskId": o.taskId, "type": "result", "state": o.state.rawValue,
                                     "message": o.message, "result": o.result, "exitCode": Int(o.exitCode)]
        if !o.diagnostics.isEmpty { fields["diagnostics"] = o.diagnostics }
        self.init(ev: "result", t: 0, code: o.diagnostics.first?["code"] as? String, severity: severity, fields: fields)
    }
}

/// 事件的去处（设计稿 EventSink）。
public struct EventSink {
    private let handler: (EngineEvent) -> Void
    public init(_ handler: @escaping (EngineEvent) -> Void) { self.handler = handler }
    public func emit(_ event: EngineEvent) { handler(event) }
    public static let discard = EventSink { _ in }
}

/// 一款游戏的设置表（设计稿：今天的 launcher.json schema 1，扩展）。行与 NX2Apple LaunchSetting 同 JSON 格式、语义键。
public struct SettingsSchema: Equatable {
    public let schema: Int
    public let rows: [LaunchSettingRow]
    public init(rows: [LaunchSettingRow]) { schema = 1; self.rows = rows }
}

/// 已经能跑的一款（run 的输入）。
public struct InstalledGame: Equatable {
    public let gameId: String
    public let name: String
    public init(gameId: String, name: String) { self.gameId = gameId; self.name = name }
}

/// 起局时冻结的设置：语义键 → 值（settingsSchema 行的 env → 值），外加宿主内提示的语言。
public struct Settings: Equatable {
    public var values: [String: String]
    /// 宿主内提示的语言（作业层只认 zh-Hans / en）。
    public var uiLanguage: String?
    public init(values: [String: String] = [:], uiLanguage: String? = nil) { self.values = values; self.uiLanguage = uiLanguage }
}

/// 在跑的一局。
public struct RunningGame: Equatable {
    public let gameId: String
    /// launch 作业的任务号。
    public let taskId: String
}

/// 对在跑一局的控制（设计稿：今天的 DM_CTL 行，带类型）。S2Arm 本刀只有停止。
public enum ControlCommand: Equatable {
    case stop
}

/// 设计稿 2.13 的 EngineProvider。
public protocol EngineProvider: AnyObject {
    var id: EngineID { get }
    var capabilities: EngineCapabilities { get }
    func inspect(_ inputs: GameInputs) async throws -> GameInfo
    func build(_ job: BuildJob, events: EventSink) async throws -> BuildResult
    func settingsSchema(for game: GameInfo) -> SettingsSchema
    func run(_ game: InstalledGame, settings: Settings, events: EventSink) throws -> RunningGame
    func control(_ game: RunningGame, _ cmd: ControlCommand)
}
