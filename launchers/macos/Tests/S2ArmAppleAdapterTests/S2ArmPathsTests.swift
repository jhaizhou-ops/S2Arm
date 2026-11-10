import XCTest
@testable import S2ArmAppleAdapter

/// 游戏库结构 P3：日志 / 任务记录目录、缺省库、搬库标记（期望按规则手写：库有标识 → <库>/logs，否则 <私有>/logs）。
final class S2ArmPathsTests: XCTestCase {
    private func temp() throws -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-paths-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }
    private func makeLibrary(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"schema":1,"id":"x"}"#.utf8).write(to: url.appendingPathComponent(".s2arm-library.json"))
    }

    /// 每款的文件（键位 input.json 等）按 catalog 给的文件夹找：英文名文件夹也对（原先按 mappings/<号>.json 拼，v3 起永远读不到）
    func testGameFilesFollowCatalogFolder() {
        let ok = GameLocation(catalog: ["state": "ok", "path": "/L", "folder": "/L/games/Animal Crossing New Horizons"])
        XCTAssertEqual(ok.file("input.json")?.path, "/L/games/Animal Crossing New Horizons/input.json")
        XCTAssertNil(GameLocation(catalog: ["state": "offline", "path": "/V", "folder": ""]).file("input.json"))
        XCTAssertNil(GameLocation(catalog: ["state": "ok", "path": "/L", "folder": ""]).file("input.json"))
    }

    func testLogsRootFollowsBuiltLibraryElsePrivate() throws {
        let r = try temp(); defer { try? FileManager.default.removeItem(at: r) }
        let priv = r.appendingPathComponent("private"), lib = r.appendingPathComponent("lib")
        XCTAssertEqual(S2ArmPaths.logsRoot(privateRoot: priv, library: "").path, priv.path + "/logs")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)   // 有文件夹、没标识 = 还没建好
        XCTAssertEqual(S2ArmPaths.logsRoot(privateRoot: priv, library: lib.path).path, priv.path + "/logs")
        try makeLibrary(lib)
        XCTAssertEqual(S2ArmPaths.logsRoot(privateRoot: priv, library: lib.path).path, lib.path + "/logs")
        XCTAssertEqual(S2ArmPaths.jobsDir(privateRoot: priv, library: lib.path).path, lib.path + "/logs/jobs")
        // 不传 library 读 preferences.json
        try FileManager.default.createDirectory(at: priv, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["library": lib.path]).write(to: priv.appendingPathComponent("preferences.json"))
        XCTAssertEqual(S2ArmPaths.logsRoot(privateRoot: priv).path, lib.path + "/logs")
    }

    func testRelocationMarkerRedirectsOnlyTheOldPath() throws {
        let r = try temp(); defer { try? FileManager.default.removeItem(at: r) }
        let priv = r.appendingPathComponent("private"), old = priv.appendingPathComponent("游戏库"), new = r.appendingPathComponent("S2Arm")
        try FileManager.default.createDirectory(at: priv, withIntermediateDirectories: true)
        try makeLibrary(new)
        try JSONSerialization.data(withJSONObject: ["from": old.path, "to": new.path, "state": "done"]).write(to: priv.appendingPathComponent("library-relocate.json"))
        XCTAssertEqual(S2ArmPaths.library(privateRoot: priv, saved: old.path), new.path)
        XCTAssertEqual(S2ArmPaths.library(privateRoot: priv, saved: "/elsewhere/lib"), "/elsewhere/lib")   // 玩家选的别处不动
        XCTAssertEqual(S2ArmPaths.library(privateRoot: priv, saved: ""), "")
        try makeLibrary(old)   // 旧位置又有库（没搬成）→ 照旧用
        XCTAssertEqual(S2ArmPaths.library(privateRoot: priv, saved: old.path), old.path)
    }

    func testDefaultLibraryStaysInCustomDataRoot() throws {
        let r = try temp(); defer { try? FileManager.default.removeItem(at: r) }
        XCTAssertEqual(S2ArmPaths.defaultLibrary(privateRoot: r).path, r.path + "/游戏库")
        XCTAssertEqual(S2ArmPaths.defaultLibrary(privateRoot: S2ArmPaths.standardPrivateRoot).path,
                       FileManager.default.homeDirectoryForCurrentUser.path + "/S2Arm")
    }
}
