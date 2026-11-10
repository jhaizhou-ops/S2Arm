// 同步判定（纯函数）。云盘目录 <玩家选的文件夹>/S2Arm Saves/<游戏号>/ 里：
//   snap-<uuid>.s2asave  一次写成后不再改
//   head-<设备 uuid>.json 每台设备只写自己这一份，iCloud 上不会出现系统级冲突副本
// 「内容」指内容标识（白名单文件的路径 + sha256 的摘要），同样的存档在任何设备上标识相同，不受 zip 时间戳影响。
import CryptoKit
import Foundation

public struct SaveFile: Equatable, Sendable {
    public let path: String
    public let sha256: String
    public init(path: String, sha256: String) { self.path = path; self.sha256 = sha256 }
}

/// 同样的文件集合得到同样的标识，和文件顺序无关
public func saveContentID(_ files: [SaveFile]) -> String {
    let text = files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        .map { "\($0.path)\u{0}\($0.sha256)\n" }.joined()
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// 版本向量：设备 uuid → 这台设备发布过几次。判断「谁更新」只看向量，不看时间、不看内容历史：
///   a 覆盖 b = 每台设备的计数 a 都不少于 b；两份互不覆盖 = 并发改过，要让玩家选。
///   大小只随设备数增长，不用截断（11-09 审查：旧方案的内容历史截 32 条，久不上传的旧版本会复活；两台设备同时处理冲突会互相包含、从此不再提示）
public typealias SaveClock = [String: Int]

public func saveClockCovers(_ a: SaveClock, _ b: SaveClock) -> Bool { b.allSatisfy { a[$0.key, default: 0] >= $0.value } }
public func saveClockMerged(_ clocks: [SaveClock]) -> SaveClock {
    clocks.reduce(into: SaveClock()) { acc, c in for (k, v) in c { acc[k] = max(acc[k, default: 0], v) } }
}

/// 本设备上次同步后的状态：内容标识 + 已经见过的版本向量
public struct SaveBase: Codable, Equatable, Sendable {
    public var content: String
    public var clock: SaveClock
    public init(content: String, clock: SaveClock) { self.content = content; self.clock = clock }
}

public struct SaveHead: Codable, Equatable, Sendable {
    public var device: String
    public var deviceName: String
    public var snapshot: String
    public var archiveSha256: String
    public var content: String
    public var clock: SaveClock
    public var savedAt: Date
    public var bytes: Int64
    /// 设备类型 mac / iphone / ipad（冲突选择里画对应图标）；没写为 nil
    public var platform: String?

    public init(device: String, deviceName: String, snapshot: String, archiveSha256: String, content: String,
                clock: SaveClock, savedAt: Date, bytes: Int64, platform: String? = nil) {
        self.device = device; self.deviceName = deviceName; self.snapshot = snapshot; self.archiveSha256 = archiveSha256
        self.content = content; self.clock = clock; self.savedAt = savedAt; self.bytes = bytes; self.platform = platform
    }
}

public enum SaveSyncDecision: Equatable, Sendable {
    case upToDate
    /// 云盘已有同样的内容，只需记下基线（合进这些版本的向量）
    case adopt([SaveHead])
    case upload
    case download(SaveHead)
    /// remotes 是与本地并列的云端版本；本地也是候选之一（没有本地存档时除外）
    case conflict(remotes: [SaveHead])
}

/// 别的设备里本机还没见过、也没被别的版本覆盖的版本；同内容只留最新一份，按时间新的在前
public func saveLeaves(_ heads: [SaveHead], device: String, seen: SaveClock) -> [SaveHead] {
    let unseen = heads.filter { $0.device != device && !saveClockCovers(seen, $0.clock) }
    let live = unseen.filter { h in !heads.contains { $0.clock != h.clock && saveClockCovers($0.clock, h.clock) } }
    var newest: [String: SaveHead] = [:]
    for h in live where newest[h.content].map({ $0.savedAt < h.savedAt }) ?? true { newest[h.content] = h }
    return newest.values.sorted { ($0.savedAt, $0.content) > ($1.savedAt, $1.content) }
}

/// local：本地内容标识，没有存档为 nil。base：上次同步后的状态，从没同步过为 nil。device：本设备 uuid（它自己的 head 不参与判定）
public func decideSaveSync(local: String?, base: SaveBase?, heads: [SaveHead], device: String) -> SaveSyncDecision {
    let leaves = saveLeaves(heads, device: device, seen: base?.clock ?? [:])
    guard let local else {
        if leaves.isEmpty { return .upToDate }
        return leaves.count == 1 ? .download(leaves[0]) : .conflict(remotes: leaves)
    }
    let same = leaves.filter { $0.content == local }
    let others = leaves.filter { $0.content != local }
    let unchanged = base?.content == local
    if others.isEmpty {
        if !same.isEmpty { return .adopt(same) }
        // 本地没改、云上也还有这份（任何一台设备的 head）才算最新；云盘被清过就重新上传
        return unchanged && heads.contains(where: { $0.content == local }) ? .upToDate : .upload
    }
    // 本地没改过、只有一份新版本、而且它是在本机这份之后改的（向量覆盖本机见过的全部）：直接取回
    if unchanged, others.count == 1, let seen = base?.clock, saveClockCovers(others[0].clock, seen) { return .download(others[0]) }
    return .conflict(remotes: others)
}
