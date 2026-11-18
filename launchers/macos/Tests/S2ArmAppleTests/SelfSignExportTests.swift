// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

/// 游戏库「导出自签包」（11-15 维护者：导出不再是装法，按钮常驻、1 下开始导出、不经装机窗）：
///   出过 iPhone 包的款 → 直接发 install 作业、带 mode = export、不带设备；没出过的 → 发出包作业（只出 iPhone、带 mode = export），记下出完接着导出。
///   期望按规则手写：看替身作业收到的请求
@MainActor final class SelfSignExportTests: XCTestCase {
    private var root: URL!
    private var model: S2ArmLauncherModel!
    private var runner: RecordingRunner!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-selfsign-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        runner = RecordingRunner()
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        model.refresh()
        for _ in 0..<300 where model.games.count < 4 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func waitFor(_ op: String) async -> [String: Any]? {
        for _ in 0..<300 { if let r = runner.requests.last(where: { $0["operation"] as? String == op }) { return r }; try? await Task.sleep(for: .milliseconds(10)) }
        return nil
    }

    private func activateHomeSelfSign(_ gameID: String, operation: String) async throws -> [String: Any]? {
        model.selectedID = gameID
        model.gamepad.source.controllers = { [] }
        let host = NSHostingView(rootView: S2ArmAppleRootView(model: model, brand: "Original UI fixture"))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1120, height: 630),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { model.gamepad.detach(); window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let target = try XCTUnwrap(model.gamepad.controlTargets(in: window).first { $0.id == "hero.selfSign" },
                                  "新版 Home 必须保留 main 的常驻导出自签包入口")
        XCTAssertTrue(window.convertToScreen(host.bounds).contains(target.frame), "导出入口必须位于窗口内")
        model.gamepad.focus(target.id)
        model.gamepad.handle(.confirm)
        return await waitFor(operation)
    }

    func testHomePackedGameExportsThroughControllerAction() async throws {
        let request = try await activateHomeSelfSign("0100A", operation: "install")
        XCTAssertEqual(request?["mode"] as? String, "export")
        XCTAssertNil(request?["device"], "导出不连手机，不带设备")
        XCTAssertFalse(runner.requests.contains { $0["operation"] as? String == "installCheck" }, "导出入口不检查装机条件")
    }

    func testHomeUnpackedGamePacksThroughControllerAction() async throws {
        let request = try await activateHomeSelfSign("0100B", operation: "export")
        XCTAssertEqual(request?["mode"] as? String, "export")
        let items = ((request?["plan"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        XCTAssertEqual(items.first?["platforms"] as? [String], ["iphone"])
        XCTAssertFalse(runner.requests.contains { $0["operation"] as? String == "installCheck" })
    }

    func testPackedGameExportsDirectly() async throws {
        let game = try XCTUnwrap(model.games.first { $0.id == "0100A" })
        XCTAssertTrue(game.iphoneExportable)
        model.exportSelfSign(game)
        let r = await waitFor("install")
        XCTAssertEqual(r?["mode"] as? String, "export", "导出：install 作业带 mode = export")
        XCTAssertNil(r?["device"], "导出不连手机，不带设备")
        XCTAssertNil(runner.requests.first { $0["operation"] as? String == "export" }, "出过包的不再出包")
    }

    func testUnpackedGamePacksThenExports() async throws {
        let game = try XCTUnwrap(model.games.first { $0.id == "0100B" })
        XCTAssertFalse(game.iphoneReady)
        model.exportSelfSign(game)
        XCTAssertTrue(model.selfSignAfterPack.contains("0100B"), "记下出完接着导出")
        let r = await waitFor("export")
        XCTAssertEqual(r?["mode"] as? String, "export", "出包作业带 mode = export（作业层步骤名照自签路写）")
        let items = ((r?["plan"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        XCTAssertEqual(items.first?["platforms"] as? [String], ["iphone"], "只出 iPhone")
    }

    /// 开发甲 11-15：出包没成（失败 / 取消）时「出完接着导出」的标记要清掉，否则这款以后正常出包被画成导出、批量装机误走导出
    func testFailedPackClearsSelfSignMark() async throws {
        let game = try XCTUnwrap(model.games.first { $0.id == "0100D" })
        model.exportSelfSign(game)
        _ = await waitFor("export")
        for _ in 0..<300 where model.busy || model.selfSignAfterPack.contains("0100D") { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.selfSignAfterPack.contains("0100D"), "出包失败：标记清掉")
        XCTAssertNil(runner.requests.first { $0["operation"] as? String == "install" }, "出包没成不接导出")
    }

    /// 11-15 维护者：出过包但包是旧格式（不能直接导出成 .img）→ 不报「请重新打 iPhone 包」，先重出 iPhone 包再导出
    func testOldFormatPackRepacksThenExports() async throws {
        let game = try XCTUnwrap(model.games.first { $0.id == "0100C" })
        XCTAssertTrue(game.iphoneReady); XCTAssertFalse(game.iphoneExportable)
        model.exportSelfSign(game)
        XCTAssertTrue(model.selfSignAfterPack.contains("0100C"))
        let r = await waitFor("export")
        XCTAssertEqual(r?["mode"] as? String, "export")
        XCTAssertNil(runner.requests.first { $0["operation"] as? String == "install" }, "旧格式不直接发导出（会失败）")
    }

    func testCancelledSelfSignDoesNotPublishFailurePill() async throws {
        runner.overrideInstallState = "cancelled"
        let game = try XCTUnwrap(model.games.first { $0.id == "0100A" })
        model.exportSelfSign(game)
        _ = await waitFor("install")
        for _ in 0..<300 where model.lastPhoneSession == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.lastPhoneSession?.phase, .finished(.cancelled))
        XCTAssertNil(model.phoneResult, "用户手动取消导出自签包，顶部不能出未完成失败胶囊")
    }
}

/// 替身作业：记下每个请求；catalog 回两款（一款出过 iPhone 包、一款没出过），其余一律成功、结果为空
private final class RecordingRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    private let lock = NSLock()
    private var seen: [[String: Any]] = []
    var overrideInstallState: String?
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return seen }
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var result: [String: Any] = [:]; var taskId = ""; var failed = false; var op = ""
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            taskId = request["taskId"] as? String ?? ""
            op = request["operation"] as? String ?? ""
            lock.lock(); seen.append(request); lock.unlock()
            let items = ((request["plan"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            failed = op == "export" && items.first?["gameId"] as? String == "0100D"   // 丁：出包失败
            if op == "catalog" {
                result = ["games": [["id": "0100A", "name": "甲", "ready": true, "missing": [], "display": "1.0.0", "iphoneReady": true, "iphoneExportable": true],
                                    ["id": "0100C", "name": "丙", "ready": true, "missing": [], "display": "1.0.0", "iphoneReady": true, "iphoneExportable": false],
                                    ["id": "0100D", "name": "丁", "ready": true, "missing": [], "display": "1.0.0"],
                                    ["id": "0100B", "name": "乙", "ready": true, "missing": [], "display": "1.0.0"]], "keys": [:]]
            }
        }
        let state = (op == "install" ? overrideInstallState : nil) ?? (failed ? "failed" : "succeeded")
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": state, "result": result, "message": failed ? "出包失败（替身）" : ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
