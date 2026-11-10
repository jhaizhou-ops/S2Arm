// 云盘文件夹读写：<玩家选的文件夹>/S2Arm Saves/<游戏号>/ 下的 snap-*.s2asave 与 head-*.json。
//   写：快照写完、读回核过 sha256 才写 head；head 整份原子替换。head 没写成，别的设备看不到这份快照。
//   读：iCloud 没下载到本机的文件（iOS 列目录里是 .<名>.icloud 占位）先要求下载、等到下载完；超时报「iCloud 还没下载完」，不碰本地存档。
//   读写都经 NSFileCoordinator，和 iCloud 同步进程互斥。
import CryptoKit
import Foundation

/// 同步失败的原因：只带结构化信息（文件名 / 设备名 / 原因），给玩家看的句子由显示端按界面语言取（#316）：
///   iOS shell/Sources/S2ArmShellHost/CloudSaves.swift `CloudSaves.message`、Mac launchers/macos/frontend S2ArmLauncherModel+CloudSaves.swift `cloudErrorText`。
///   errorDescription 只是日志 / 兜底用的英文，界面不要直接显示它
public enum SaveSyncError: Error, Equatable, LocalizedError, Sendable {
    /// iCloud 里的文件还没下载到这台设备（文件名）
    case notDownloaded(String)
    /// 读回的快照和 head 里记的 sha256 不符（传了一半或被改过；快照文件名）
    case corrupt(String)
    /// 本机存档已经换成 from 的进度，但写回 iCloud 失败（来源设备名，失败原因；下次同步会再写）
    case cloudWriteAfterRestore(String, String)

    public var errorDescription: String? {
        switch self {
        case .notDownloaded(let name): return "SaveSync: \(name) is not downloaded from iCloud yet; local save unchanged"
        case .corrupt(let name): return "SaveSync: \(name) in iCloud is incomplete; local save unchanged"
        case .cloudWriteAfterRestore(let from, let why): return "SaveSync: restored progress from \(from) but writing back to iCloud failed (\(why))"
        }
    }
}

public func sha256File(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

public struct CloudSaveFolder: Sendable {
    public let directory: URL
    /// 等 iCloud 下载一份文件的上限（秒）
    public var downloadTimeout: TimeInterval = 60

    public init(root: URL, gameID: String) {
        // 游戏号统一大写：iOS 一侧已转大写，Mac 用库里的原样，两端必须落到同一个目录（11-09 审查疑点）
        directory = root.appendingPathComponent("S2Arm Saves", isDirectory: true).appendingPathComponent(gameID.uppercased(), isDirectory: true)
    }

    static func headName(_ device: String) -> String { "head-\(device).json" }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// 目录里的文件名（iCloud 占位 .<名>.icloud 还原成真名）
    func names() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).map { name in
            name.hasPrefix(".") && name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(".icloud".count)) : name
        }
    }

    /// 所有设备的 head。读不懂的 head（别的版本 / 写坏）跳过，不拦这次同步；没下载完的一起等（共用一个时限），等不到就报错
    public func heads() throws -> [SaveHead] {
        let urls = try names().filter { $0.hasPrefix("head-") && $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
        try waitDownloaded(urls)
        return urls.compactMap { try? Self.decoder.decode(SaveHead.self, from: coordinatedRead($0)) }
    }

    /// 把 head 指的快照拷到 destination（不能已存在），核 sha256；不符删掉拷出的文件、报错
    public func download(_ head: SaveHead, to destination: URL) throws {
        let url = directory.appendingPathComponent(head.snapshot)
        try waitDownloaded([url])
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { real in
            do { try FileManager.default.copyItem(at: real, to: destination) } catch { failure = error }
        }
        if let e = coordinationError ?? failure { throw e }
        guard try sha256File(destination) == head.archiveSha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw SaveSyncError.corrupt(head.snapshot)
        }
    }

    /// 发布第一步：本地快照拷成 snapshot（一次写成，名字含 uuid 不会撞），读回核 sha256
    public func putSnapshot(_ archive: URL, as snapshot: String, sha256: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(snapshot)
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { real in
            do { try FileManager.default.copyItem(at: archive, to: real) } catch { failure = error }
        }
        if let e = coordinationError ?? failure { throw e }
        guard try sha256File(url) == sha256 else {
            try? FileManager.default.removeItem(at: url)
            throw SaveSyncError.corrupt(snapshot)
        }
    }

    /// 发布第二步：整份替换本设备的 head（写临时文件再改名）
    public func putHead(_ head: SaveHead) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(head)
        let url = directory.appendingPathComponent(Self.headName(head.device))
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { real in
            do { try data.write(to: real, options: .atomic) } catch { failure = error }
        }
        if let e = coordinationError ?? failure { throw e }
    }

    /// 只删本设备自己写的快照：留最近 keep 份，任何 head 还指着的不删。删不掉不算失败（下次再删）
    public func prune(device: String, keep: Int, heads: [SaveHead]) {
        let referenced = Set(heads.map(\.snapshot))
        let prefix = "snap-\(device)-"
        guard let own = try? names().filter({ $0.hasPrefix(prefix) && $0.hasSuffix(".s2asave") }) else { return }
        let dated = own.map { name -> (String, Date) in
            let url = directory.appendingPathComponent(name)
            return (name, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (name, _) in dated.dropFirst(keep) where !referenced.contains(name) {
            let url = directory.appendingPathComponent(name)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { real in
                try? FileManager.default.removeItem(at: real)
            }
        }
    }

    func coordinatedRead(_ url: URL) throws -> Data {
        var data: Data?, failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { real in
            do { data = try Data(contentsOf: real) } catch { failure = error }
        }
        if let e = coordinationError ?? failure { throw e }
        return data ?? Data()
    }

    /// 不在 iCloud 里的文件（普通文件夹、单测）状态为空、文件在就算好。几份文件先一起要求下载，再共用 downloadTimeout 等；
    ///   外层 Task 取消就抛 CancellationError（iOS 同步页「跳过」）。
    ///   「已下载但不一定最新」（.downloaded）也算好：离线时不必等满时限才能开局；读到旧 head 的代价是之后多问一次冲突，不丢进度
    func waitDownloaded(_ urls: [URL]) throws {
        let fm = FileManager.default
        func ready(_ url: URL) -> Bool {
            var u = url; u.removeAllCachedResourceValues()
            let status = try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            return fm.fileExists(atPath: url.path) && (status == nil || status == .current || status == .downloaded)
        }
        var pending = urls.filter { !ready($0) }
        if pending.isEmpty { return }
        pending.forEach { try? fm.startDownloadingUbiquitousItem(at: $0) }
        let deadline = Date().addingTimeInterval(downloadTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            pending.removeAll(where: ready)
            if pending.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw SaveSyncError.notDownloaded(pending[0].lastPathComponent)
    }
}
