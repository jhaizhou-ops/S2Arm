import XCTest
import AppKit
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

// 游戏库刷新失败（P1-148）：启动先显示的上次列表要一直标成「上次的」，并带上失败原因给库页提示条；没有上次列表时不出这条提示。
// 资源目录是空的临时目录：catalog 作业起不来，必然走失败分支（不依赖真后端）。
@MainActor final class LibraryStaleTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-stale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("jobs"), withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func model(snapshot: Bool) throws -> S2ArmLauncherModel {
        if snapshot {
            let saved = #"{"libraryId":"lib-1","result":{"games":[{"id":"0100A","name":"Alpha","ready":true,"missing":[]}],"keys":{}}}"#
            try Data(saved.utf8).write(to: root.appendingPathComponent("library-snapshot.json"))
        }
        return S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "lib-1")))
    }

    private func settle(_ m: S2ArmLauncherModel) async {
        for _ in 0..<200 where m.loading { try? await Task.sleep(nanoseconds: 25_000_000) }
    }

    func testFailedRefreshKeepsSnapshotMarkedAsLastTime() async throws {
        let m = try model(snapshot: true)
        m.refresh()
        XCTAssertEqual(m.games.map(\.id), ["0100A"], "先显示上次的列表")
        XCTAssertTrue(m.showingSnapshot)
        await settle(m)
        XCTAssertFalse(m.loading)
        XCTAssertNotNil(m.libraryError)
        XCTAssertEqual(m.games.map(\.id), ["0100A"], "失败不清空列表")
        XCTAssertTrue(m.showingSnapshot, "失败后仍标成上次的列表")
        XCTAssertEqual(m.staleLibraryError, m.libraryError)
    }

    func testFailureWithoutSnapshotShowsNoStaleBanner() async throws {
        let m = try model(snapshot: false)
        m.refresh()
        await settle(m)
        XCTAssertNotNil(m.libraryError)
        XCTAssertFalse(m.showingSnapshot)
        XCTAssertNil(m.staleLibraryError, "没有上次的列表：走欢迎页的报错，不出「上次的列表」")
    }
}
