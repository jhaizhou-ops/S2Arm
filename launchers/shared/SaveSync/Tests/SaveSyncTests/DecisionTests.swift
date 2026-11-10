import Foundation
import Testing
@testable import SaveSync

/// 期望值全部按 SaveSyncCore 的规则手写（版本向量：a 覆盖 b = 每台设备计数都不少于 b），不调用被测函数算期望
private func head(_ device: String, _ content: String, _ clock: SaveClock, at: TimeInterval = 0) -> SaveHead {
    SaveHead(device: device, deviceName: device, snapshot: "snap-\(content)", archiveSha256: "z\(content)", content: content,
             clock: clock, savedAt: Date(timeIntervalSince1970: at), bytes: 1)
}
private func base(_ content: String, _ clock: SaveClock) -> SaveBase { SaveBase(content: content, clock: clock) }

@Test func contentIDIgnoresFileOrderAndDetectsChange() {
    let a = SaveFile(path: "a", sha256: "1"), b = SaveFile(path: "b", sha256: "2"), changed = SaveFile(path: "b", sha256: "3")
    #expect(saveContentID([a, b]) == saveContentID([b, a]))
    #expect(saveContentID([a, b]) != saveContentID([a, changed]))
    // printf 'a\0001\nb\0002\n' | shasum -a 256 的结果
    #expect(saveContentID([a, b]) == "1a04f75bd0704a1e3a5609aa6cef325ce65e2ccde2c36252d0e2fc2ddcb5762d")
}

@Test func clockCoverAndMerge() {
    #expect(saveClockCovers(["a": 2, "b": 1], ["a": 1]))
    #expect(saveClockCovers(["a": 1], ["a": 1]))
    #expect(!saveClockCovers(["a": 2], ["a": 1, "b": 1]))
    #expect(saveClockCovers(["a": 1], [:]))
    #expect(saveClockMerged([["a": 2, "b": 1], ["a": 1, "c": 3]]) == ["a": 2, "b": 1, "c": 3])
}
@Test func nothingAnywhere() { #expect(decideSaveSync(local: nil, base: nil, heads: [], device: "me") == .upToDate) }
@Test func noLocalOneRemoteDownloads() {
    let r = head("m", "R", ["m": 1])
    #expect(decideSaveSync(local: nil, base: nil, heads: [r], device: "me") == .download(r))
}
@Test func noLocalTwoConcurrentRemotesAsks() {
    let r1 = head("m", "R1", ["m": 1], at: 1), r2 = head("p", "R2", ["p": 1], at: 2)
    #expect(decideSaveSync(local: nil, base: nil, heads: [r1, r2], device: "me") == .conflict(remotes: [r2, r1]))
}
@Test func firstEverUpload() { #expect(decideSaveSync(local: "L", base: nil, heads: [], device: "me") == .upload) }
@Test func sameContentAdoptsBase() {
    let m = head("m", "X", ["m": 1])
    #expect(decideSaveSync(local: "X", base: nil, heads: [m], device: "me") == .adopt([m]))
}
@Test func unchangedAndAlreadySeenIsUpToDate() {
    let mine = head("me", "B", ["me": 1])
    #expect(decideSaveSync(local: "B", base: base("B", ["me": 1]), heads: [mine], device: "me") == .upToDate)
}
@Test func unchangedButCloudClearedUploadsAgain() {
    #expect(decideSaveSync(local: "B", base: base("B", ["me": 1]), heads: [], device: "me") == .upload)
}
@Test func localChangedNothingNewUploads() {
    let mine = head("me", "B", ["me": 1])
    #expect(decideSaveSync(local: "L", base: base("B", ["me": 1]), heads: [mine], device: "me") == .upload)
}
@Test func unchangedLocalNewerRemoteDownloads() {
    let r = head("m", "R", ["me": 1, "m": 1])
    #expect(decideSaveSync(local: "B", base: base("B", ["me": 1]), heads: [head("me", "B", ["me": 1]), r], device: "me") == .download(r))
}
@Test func bothChangedAsks() {
    let r = head("m", "R", ["me": 1, "m": 1])
    #expect(decideSaveSync(local: "L", base: base("B", ["me": 1]), heads: [head("me", "B", ["me": 1]), r], device: "me") == .conflict(remotes: [r]))
}
@Test func freshDeviceWithUnrelatedLocalAsks() {
    let r = head("m", "R", ["m": 1])
    #expect(decideSaveSync(local: "L", base: nil, heads: [r], device: "me") == .conflict(remotes: [r]))
}
@Test func unchangedButRemoteBranchedEarlierAsks() {   // 对方从更早的版本改的（没见过本机这份）：直接下载会丢掉本机已同步的进度
    let mine = head("me", "B", ["me": 2]), r = head("m", "R", ["me": 1, "m": 1], at: 9)
    #expect(decideSaveSync(local: "B", base: base("B", ["me": 2]), heads: [mine, r], device: "me") == .conflict(remotes: [r]))
}
@Test func ownHeadIsNeverACandidate() {   // 11-09 真机：本机上次写的 head 曾被列成「另一台 iPhone」；只下载过的设备 head 停在旧内容也一样
    let stale = head("me", "OLD", ["me": 1]), mac = head("m", "M", ["me": 1, "m": 5])
    #expect(decideSaveSync(local: "L", base: base("M2", ["me": 1, "m": 4]), heads: [stale, mac], device: "me") == .conflict(remotes: [mac]))
    #expect(decideSaveSync(local: "M", base: base("M", ["me": 1, "m": 5]), heads: [stale, mac], device: "me") == .upToDate)
}
@Test func longSilentDeviceDoesNotComeBack() {   // 11-09 审查：iPhone 只上传过一次 P0，Mac 之后上传 40 次；P0 已被 Mac 见过，不该复活
    let p0 = head("phone", "P0", ["phone": 1], at: 1), mac = head("mac", "M40", ["phone": 1, "mac": 40], at: 50)
    #expect(decideSaveSync(local: "M40", base: base("M40", ["phone": 1, "mac": 40]), heads: [p0, mac], device: "mac") == .upToDate)
    #expect(decideSaveSync(local: "M41", base: base("M40", ["phone": 1, "mac": 40]), heads: [p0, mac], device: "mac") == .upload)
}
@Test func threeDevicesTwoLeavesAsks() {
    let a = head("a", "A", ["me": 1, "a": 1], at: 1), c = head("c", "C", ["me": 1, "c": 1], at: 2)
    #expect(decideSaveSync(local: "L", base: base("B", ["me": 1]), heads: [head("me", "B", ["me": 1]), a, c], device: "me") == .conflict(remotes: [c, a]))
}
@Test func supersededHeadIsNotACandidate() {
    let old = head("a", "A", ["a": 1]), new = head("c", "C", ["a": 1, "c": 1])
    #expect(saveLeaves([old, new], device: "me", seen: [:]) == [new])
}
@Test func sameContentTwoDevicesKeepsNewest() {
    let a = head("a", "X", ["a": 1], at: 1), b = head("b", "X", ["b": 1], at: 5)
    #expect(saveLeaves([a, b], device: "me", seen: [:]) == [b])
}
@Test func concurrentResolutionsStillConflictThenConverge() {   // 11-09 审查：两台设备几乎同时各自选定，旧方案互相包含后从此不再提示、再静默覆盖
    // A 先发 L {A:1}，B 并发发 R {B:1}；两边各自冲突、都选「保留本机」：A → {A:2,B:1}，B → {A:1,B:2}
    let a2 = head("A", "L", ["A": 2, "B": 1], at: 3), b2 = head("B", "R", ["A": 1, "B": 2], at: 4)
    // 互不覆盖：两边下次同步都还要问
    #expect(decideSaveSync(local: "L", base: base("L", ["A": 2, "B": 1]), heads: [a2, b2], device: "A") == .conflict(remotes: [b2]))
    #expect(decideSaveSync(local: "R", base: base("R", ["A": 1, "B": 2]), heads: [a2, b2], device: "B") == .conflict(remotes: [a2]))
    // A 再次选保留 → {A:3,B:2} 覆盖 B 的版本；B 本地没改 → 直接取回 A 这份，收敛
    let a3 = head("A", "L", ["A": 3, "B": 2], at: 5)
    #expect(decideSaveSync(local: "R", base: base("R", ["A": 1, "B": 2]), heads: [a3, b2], device: "B") == .download(a3))
    #expect(decideSaveSync(local: "L", base: base("L", ["A": 3, "B": 2]), heads: [a3, b2], device: "A") == .upToDate)
}
@Test func headWithoutPlatformStillDecodes() throws {
    let json = #"{"archiveSha256":"z","bytes":1,"clock":{"d":1},"content":"C","device":"d","deviceName":"iPhone","savedAt":"2026-11-09T17:26:34Z","snapshot":"s"}"#
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    let h = try d.decode(SaveHead.self, from: Data(json.utf8))
    #expect(h.platform == nil && h.clock == ["d": 1])
}
