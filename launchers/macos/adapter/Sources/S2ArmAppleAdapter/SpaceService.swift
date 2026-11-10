import Foundation

/// 一款里可以勾选删除的一项（spaceSurvey 作业 result.games[].parts 的一项：unpack / intermediate / shaders / mac / ipa）。
/// title、rebuild（删了会怎样）是作业层的定句（pack/jobs/library.py SPACE_PARTS），原样显示。
public struct SpacePart: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let rebuild: String
    public let bytes: Int64

    public init(id: String, title: String = "", rebuild: String = "", bytes: Int64) {
        self.id = id; self.title = title; self.rebuild = rebuild; self.bytes = bytes
    }

    init?(json p: [String: Any]) {
        guard let id = p["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, title: p["title"] as? String ?? id, rebuild: p["rebuild"] as? String ?? "",
                  bytes: (p["bytes"] as? NSNumber)?.int64Value ?? 0)
    }
}

/// 一款的占用：parts 可勾选删除；kept（saves 存档 / logs 日志）只报大小、不给删。
public struct GameSpace: Identifiable, Equatable {
    public var id: String { gameId }
    public let gameId: String
    public let name: String
    public let parts: [SpacePart]
    public let kept: [SpacePart]

    public init(gameId: String, name: String, parts: [SpacePart], kept: [SpacePart]) {
        self.gameId = gameId; self.name = name; self.parts = parts; self.kept = kept
    }

    init?(json g: [String: Any]) {
        guard let id = g["gameId"] as? String, !id.isEmpty else { return nil }
        self.init(gameId: id, name: g["name"] as? String ?? id,
                  parts: (g["parts"] as? [[String: Any]] ?? []).compactMap(SpacePart.init(json:)),
                  kept: (g["kept"] as? [[String: Any]] ?? []).compactMap(SpacePart.init(json:)))
    }

    /// 勾了这些部件一共能释放多少。
    public func bytes(of ids: Set<String>) -> Int64 { parts.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.bytes } }
}

/// 一次释放的结局（spaceFree 作业 result）：各部件删掉的字节与合计。
public struct SpaceFreed: Equatable {
    public let gameId: String
    public let parts: [SpacePart]
    public let freedBytes: Int64
}

/// 存储总览（storageOverview 作业，pack/jobs/sizes.py overview）：各存放位置的总量 / 剩余 / S2Arm 已用，公共件各占多少，每款大小。
public struct StorageOverview: Equatable {
    public struct Location: Identifiable, Equatable {
        public let id: String
        public let path: String
        public let volume: String
        public let connected: Bool
        public let isDefault: Bool
        /// 没连上时为 nil
        public let totalBytes: Int64?
        public let freeBytes: Int64?
        public let usedBytes: Int64?
    }
    public struct Game: Identifiable, Equatable {
        public var id: String { gameId }
        public let gameId: String
        public let name: String
        public let state: String
        public let sizes: GameSizes
    }
    public let locations: [Location]
    /// hosts / ipa / toolCache / temp / logs（作业层顺序）
    public let shared: [SpacePart]
    public let games: [Game]

    public init(json r: [String: Any]) {
        func n(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }
        locations = (r["locations"] as? [[String: Any]] ?? []).compactMap { l in
            guard let id = l["id"] as? String, let path = l["path"] as? String else { return nil }
            return Location(id: id, path: path, volume: l["volume"] as? String ?? "", connected: l["connected"] as? Bool ?? false,
                            isDefault: l["default"] as? Bool ?? false, totalBytes: n(l["totalBytes"]), freeBytes: n(l["freeBytes"]), usedBytes: n(l["usedBytes"]))
        }
        shared = (r["shared"] as? [[String: Any]] ?? []).compactMap(SpacePart.init(json:))
        games = (r["games"] as? [[String: Any]] ?? []).compactMap { g in
            guard let id = g["gameId"] as? String, !id.isEmpty else { return nil }
            return Game(gameId: id, name: g["name"] as? String ?? id, state: g["state"] as? String ?? "none",
                        sizes: GameSizes(catalog: g["sizes"] as? [String: Any] ?? [:]))
        }
    }
}

/// 释放空间：spaceSurvey 列每款按部件的占用，spaceFree 删勾选的部件（直接删、不进废纸篓；有任务在跑作业层拒绝）。
public final class SpaceService {
    private let client: JobClient

    public init(client: JobClient) { self.client = client }

    public static let nothingChosen = "没有勾选要删除的项。"

    /// 列占用（gameId 给了只这一款，不给列全部款）。没配游戏库直接抛错，不起作业。
    public func survey(gameId: String? = nil) async throws -> [GameSpace] {
        guard !client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        var extra: [String: Any] = [:]
        if let gameId { extra["gameId"] = gameId }
        let result = try await client.perform("spaceSurvey", extra: extra).result
        return (result["games"] as? [[String: Any]] ?? []).compactMap(GameSpace.init(json:))
    }

    /// 存储总览（storageOverview）。没配游戏库直接抛错，不起作业。
    public func overview() async throws -> StorageOverview {
        guard !client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        return StorageOverview(json: try await client.perform("storageOverview").result)
    }

    /// 删这款勾选的部件。没勾 / 没配游戏库不起作业。作业层拒绝（另一个任务在用游戏库）抛 JobFailure，message 是作业层原话。
    public func free(gameId: String, parts: [String], events: EventSink = .discard) async throws -> SpaceFreed {
        guard !client.environment.library.isEmpty else { throw JobClientError(LibraryProvider.noLibraryMessage) }
        guard !parts.isEmpty else { throw JobClientError(Self.nothingChosen) }
        let r = try await client.perform("spaceFree", extra: ["gameId": gameId, "parts": parts], events: events).result
        return SpaceFreed(gameId: r["gameId"] as? String ?? gameId,
                          parts: (r["parts"] as? [[String: Any]] ?? []).compactMap(SpacePart.init(json:)),
                          freedBytes: (r["freedBytes"] as? NSNumber)?.int64Value ?? 0)
    }
}
