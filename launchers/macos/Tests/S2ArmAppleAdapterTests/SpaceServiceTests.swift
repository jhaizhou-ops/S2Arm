import Foundation
import XCTest
@testable import S2ArmAppleAdapter

private func result(_ json: String, state: String = "succeeded", message: String = "操作完成") -> String {
    eventLine("result", state: state, message: message, extra: #","result":"# + json)
}

final class SpaceServiceTests: XCTestCase {
    private static let survey = #"{"games":[{"gameId":"0100A","name":"Alpha","parts":[{"id":"unpack","title":"解包与构建缓存","rebuild":"下次出包会重新解包","bytes":4096},{"id":"intermediate","title":"出包中间产物","rebuild":"下次出包会重新生成","bytes":0},{"id":"shaders","title":"着色器与出包缓存","rebuild":"r","bytes":8192},{"id":"mac","title":"Mac 运行版本","rebuild":"r","bytes":1000},{"id":"ipa","title":"已出好的 iPhone 包","rebuild":"r","bytes":3000000000}],"kept":[{"id":"saves","bytes":512},{"id":"logs","bytes":0}]},{"name":"no id"}]}"#

    func testSurveyAsksForOneGameAndReadsPartsAndKept() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([result(Self.survey)], 0, false) }
        let games = try await SpaceService(client: client(box, runner)).survey(gameId: "0100A")
        XCTAssertEqual(runner.starts.first?.request["operation"] as? String, "spaceSurvey")
        XCTAssertEqual(runner.starts.first?.request["gameId"] as? String, "0100A")
        XCTAssertEqual(games.map(\.gameId), ["0100A"])   // 没 gameId 的不要
        let g = games[0]
        XCTAssertEqual(g.parts.map(\.id), ["unpack", "intermediate", "shaders", "mac", "ipa"])
        XCTAssertEqual(g.parts[0], SpacePart(id: "unpack", title: "解包与构建缓存", rebuild: "下次出包会重新解包", bytes: 4096))
        XCTAssertEqual(g.parts[4].bytes, 3_000_000_000)   // 超过 Int32 不截断
        XCTAssertEqual(g.kept.map(\.id), ["saves", "logs"])
        XCTAssertEqual(g.kept[0].bytes, 512)
        XCTAssertEqual(g.bytes(of: ["unpack", "shaders", "saves"]), 4096 + 8192)   // 只算可删的部件
    }

    func testSurveyWithoutGameIdListsAllAndNoLibraryStartsNothing() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([result(Self.survey)], 0, false) }
        _ = try await SpaceService(client: client(box, runner)).survey()
        XCTAssertNil(runner.starts.first?.request["gameId"])
        let bare = FakeRunner()
        do { _ = try await SpaceService(client: client(box, bare, env: box.environment(library: ""))).survey(); XCTFail() }
        catch { XCTAssertEqual((error as? JobClientError)?.message, LibraryProvider.noLibraryMessage) }
        XCTAssertTrue(bare.starts.isEmpty)
    }

    func testFreeSendsChosenPartsAndReadsFreedBytes() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([result(#"{"gameId":"0100A","parts":[{"id":"ipa","bytes":3000000000}],"freedBytes":3000000000}"#)], 0, false) }
        let freed = try await SpaceService(client: client(box, runner)).free(gameId: "0100A", parts: ["ipa"])
        let req = runner.starts.first?.request ?? [:]
        XCTAssertEqual(req["operation"] as? String, "spaceFree")
        XCTAssertEqual(req["gameId"] as? String, "0100A")
        XCTAssertEqual(req["parts"] as? [String], ["ipa"])
        XCTAssertEqual(req["library"] as? String, box.root.appendingPathComponent("lib").path)   // 契约必填 library
        XCTAssertEqual(freed, SpaceFreed(gameId: "0100A", parts: [SpacePart(id: "ipa", title: "ipa", bytes: 3_000_000_000)], freedBytes: 3_000_000_000))
    }

    func testFreeWithNothingChosenStartsNothing() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        do { _ = try await SpaceService(client: client(box, runner)).free(gameId: "0100A", parts: []); XCTFail() }
        catch { XCTAssertEqual((error as? JobClientError)?.message, SpaceService.nothingChosen) }
        XCTAssertTrue(runner.starts.isEmpty)
    }

    func testBusyLibraryRefusalCarriesTheJobMessage() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([result("{}", state: "failed", message: "另一个任务正在使用游戏库，请稍后重试。")], 1, false) }
        do { _ = try await SpaceService(client: client(box, runner)).free(gameId: "0100A", parts: ["ipa"]); XCTFail() }
        catch let failure as JobFailure {
            XCTAssertEqual(failure.state, .failed)
            XCTAssertEqual(failure.errorDescription, "另一个任务正在使用游戏库，请稍后重试。")
        }
    }

    func testOverviewReadsLocationsSharedAndGameSizes() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([result(#"{"locations":[{"id":"L1","path":"/ext/a/lib","volume":"A","connected":true,"default":true,"totalBytes":5000000000,"freeBytes":2000000000,"usedBytes":3000000000},{"id":"L2","path":"/ext/b/lib","volume":"B","connected":false,"default":false},{"path":"no id"}],"shared":[{"id":"hosts","bytes":10},{"id":"ipa","bytes":20},{"id":"toolCache","bytes":0},{"id":"temp","bytes":0},{"id":"logs","bytes":5}],"games":[{"gameId":"0100A","name":"Alpha","state":"ok","sizes":{"imageMac":1,"imageIos":2,"saves":3,"cache":4,"sources":4000000000,"measured":true}},{"gameId":"0100B","state":"offline","sizes":{"sources":7,"measured":false}}]}"#)], 0, false) }
        let o = try await SpaceService(client: client(box, runner)).overview()
        XCTAssertEqual(runner.starts.first?.request["operation"] as? String, "storageOverview")
        XCTAssertEqual(o.locations.map(\.id), ["L1", "L2"])   // 没 id 的不要
        XCTAssertEqual(o.locations[0].isDefault, true)
        XCTAssertEqual(o.locations[0].usedBytes, 3_000_000_000)   // 超过 Int32 不截断
        XCTAssertEqual(o.locations[1].connected, false)
        XCTAssertNil(o.locations[1].freeBytes)   // 没连上：不给假的 0
        XCTAssertEqual(o.shared.map(\.id), ["hosts", "ipa", "toolCache", "temp", "logs"])
        XCTAssertEqual(o.shared.map(\.bytes), [10, 20, 0, 0, 5])
        XCTAssertEqual(o.games[0].sizes, GameSizes(imageMac: 1, imageIos: 2, saves: 3, cache: 4, sources: 4_000_000_000, measured: true))
        XCTAssertEqual(o.games[1].name, "0100B")   // 没名字退回游戏号
        XCTAssertEqual(o.games[1].sizes, GameSizes(imageMac: 0, imageIos: 0, saves: 0, cache: 0, sources: 7, measured: false))
    }

    func testOverviewWithoutLibraryStartsNothing() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let bare = FakeRunner()
        do { _ = try await SpaceService(client: client(box, bare, env: box.environment(library: ""))).overview(); XCTFail() }
        catch { XCTAssertEqual((error as? JobClientError)?.message, LibraryProvider.noLibraryMessage) }
        XCTAssertTrue(bare.starts.isEmpty)
    }
}

final class LibraryChangeTests: XCTestCase {
    func testChangeRunsSetupThenWritesOnlyTheLibraryKeys() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let prefs = box.privateRoot.appendingPathComponent("preferences.json")
        try Data(#"{"library":"/old","libraryId":"old-id","developerDir":"/X","docked":true}"#.utf8).write(to: prefs)
        let runner = FakeRunner()
        runner.script = { _ in ([result(#"{"library":"/Users/player/Games/S2Arm 游戏库","libraryId":"new-id"}"#)], 0, false) }
        let c = client(box, runner)
        let library = try await LibraryProvider(client: c).change(to: URL(fileURLWithPath: "/Users/player/Games/S2Arm 游戏库"))
        let req = runner.starts.first?.request ?? [:]
        XCTAssertEqual(req["operation"] as? String, "setup")
        XCTAssertEqual(req["library"] as? String, "/Users/player/Games/S2Arm 游戏库")
        XCTAssertEqual(req["libraryId"] as? String, "")   // 新库还没有标识，作业层认出 / 新建
        XCTAssertEqual(library, "/Users/player/Games/S2Arm 游戏库")
        XCTAssertEqual(c.environment.library, "/Users/player/Games/S2Arm 游戏库")
        XCTAssertEqual(c.environment.libraryId, "new-id")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: prefs)) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["library"] as? String, "/Users/player/Games/S2Arm 游戏库")
        XCTAssertEqual(saved["libraryId"] as? String, "new-id")
        XCTAssertEqual(saved["developerDir"] as? String, "/X")   // 别的字段原样
        XCTAssertEqual(saved["docked"] as? Bool, true)
        let mode = (try FileManager.default.attributesOfItem(atPath: prefs.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        // 重新读回来也是新库
        XCTAssertEqual(JobEnvironment.load(privateRoot: box.privateRoot, resources: box.resources).libraryId, "new-id")
    }

    func testRefusedSetupChangesNothing() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let prefs = box.privateRoot.appendingPathComponent("preferences.json")
        try Data(#"{"library":"/old","libraryId":"old-id"}"#.utf8).write(to: prefs)
        let runner = FakeRunner()
        let cloud = "游戏库在云盘同步目录里（iCloud 云盘）。"
        runner.script = { _ in ([result("{}", state: "failed", message: cloud)], 1, false) }
        let c = client(box, runner)
        let before = c.environment
        do { _ = try await LibraryProvider(client: c).change(to: URL(fileURLWithPath: "/Users/player/Library/Mobile Documents/lib")); XCTFail() }
        catch let failure as JobFailure { XCTAssertEqual(failure.errorDescription, cloud) }
        XCTAssertEqual(c.environment, before)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: prefs)) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["libraryId"] as? String, "old-id")
    }
}
