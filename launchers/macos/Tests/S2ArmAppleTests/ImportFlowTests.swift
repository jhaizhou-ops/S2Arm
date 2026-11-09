// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

@MainActor final class ImportFlowTests: XCTestCase {
    private var root: URL!
    private var runner: ImportRunner!
    private var model: S2ArmLauncherModel!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = root.appendingPathComponent("Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try Data().write(to: jobs.appendingPathComponent("main.py"))
        runner = ImportRunner()
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"),
            runner: runner))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testControlImportKeepsFailureAndDoesNotOpenImportSheet() async throws {
        let control = try S2ArmControl(model: model) { XCTFail($0) }
        defer { control.stop() }
        let response = await control.handle(ControlRequest(method: "POST", path: "/games", headers: [:], body: ["paths": ["/fixture.nsp"]]))
        XCTAssertEqual(response.code, 200)
        await waitForImport()
        XCTAssertEqual(runner.imports.count, 1)
        XCTAssertNotEqual(runner.imports.first?["partialResults"] as? Bool, true)
        XCTAssertEqual(model.inlineFailure?.message, "Fixture failure")
        XCTAssertFalse(model.showAddGames)
        XCTAssertFalse(model.showKeys)
    }

    func testUserImportAndRetryOnlySubmitUnsuccessfulSourcesOnce() async {
        let a = URL(fileURLWithPath: "/first/game.nsp")
        let b = URL(fileURLWithPath: "/second/game.nsp")
        runner.response = { _ in ("succeeded", ["sources": [self.row("a", a, "imported"), self.row("b", b, "failed")]]) }
        model.importGames([a, b], partialResults: true)
        XCTAssertTrue(model.showAddGames)
        await waitForImport()
        XCTAssertEqual(ImportSheet(model: model, kind: .games).page, .results)
        XCTAssertEqual(model.importedSourceCount, 1)
        XCTAssertEqual(model.pendingSources.map(\.id), ["b"])
        runner.response = { _ in ("succeeded", ["sources": [self.row("b", b, "failed")]]) }
        model.retryImport()
        model.retryImport()
        await waitForImport()
        XCTAssertEqual(runner.imports.count, 2)
        XCTAssertEqual(runner.imports.last?["paths"] as? [String], [b.path])
        XCTAssertTrue(runner.imports.allSatisfy { $0["partialResults"] as? Bool == true })
        XCTAssertEqual(model.importedSourceCount, 1)
    }

    func testCancelRetryClosesImmediatelyAndDoesNotReopen() async {
        let a = URL(fileURLWithPath: "/first.nsp")
        let b = URL(fileURLWithPath: "/second.nsp")
        runner.response = { _ in ("succeeded", ["sources": [self.row("a", a, "imported"), self.row("b", b, "failed")]]) }
        model.importGames([a, b], partialResults: true)
        await waitForImport()
        runner.response = { _ in ("hold", [:]) }
        model.retryImport()
        for _ in 0..<200 where runner.imports.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        model.cancelImport()
        XCTAssertFalse(model.showAddGames)
        XCTAssertTrue(model.busy)
        await waitForImport()
        XCTAssertEqual(runner.cancellations, 1)
        XCTAssertEqual(runner.imports.last?["paths"] as? [String], [b.path])
        XCTAssertNil(model.importPage)
        XCTAssertFalse(model.showAddGames)
    }

    func testKeysContinuePendingSourcesInSameSheet() async {
        let a = URL(fileURLWithPath: "/first.nsp")
        let b = URL(fileURLWithPath: "/second.nsp")
        model.showKeys = true
        runner.response = { _ in ("succeeded", ["sources": [self.row("a", a, "imported"), self.row("b", b, "failed")]]) }
        model.importGames([a, b], partialResults: true)
        await waitForImport()
        XCTAssertEqual(ImportSheet(model: model, kind: .keys).page, .results)
        model.backFromImportResults()
        XCTAssertEqual(ImportSheet(model: model, kind: .keys).page, .keys)
        runner.response = { _ in ("succeeded", ["sources": [self.row("b", b, "failed")]]) }
        model.importKeys(URL(fileURLWithPath: "/fixture.keys"))
        await waitForImport()
        XCTAssertEqual(runner.imports.last?["paths"] as? [String], [b.path])
        XCTAssertTrue(model.showKeys)
        XCTAssertFalse(model.showAddGames)
        XCTAssertEqual(ImportSheet(model: model, kind: .keys).page, .results)
        XCTAssertEqual(model.importedSourceCount, 1)
    }

    func testBackForKeylessSourcesReturnsToSelectionAndCopyIsComplete() async throws {
        let source = URL(fileURLWithPath: "/sample.nup")
        let text = "First line\n" + String(repeating: "synthetic [REDACTED]\n", count: 300) + "Last line"
        runner.response = { _ in ("succeeded", ["sources": [self.row("a", source, "failed", needsKeys: false, diagnostic: text)]]) }
        model.showAddGames = true
        model.importGames([source], partialResults: true)
        await waitForImport()
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(ImportSheet.copyDiagnostic(try XCTUnwrap(model.pendingSources.first), to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        model.backFromImportResults()
        XCTAssertEqual(ImportSheet(model: model, kind: .games).page, .selection)
        XCTAssertTrue(model.pendingImport.isEmpty)
    }

    func testRetryReplacesDirectoryPlaceholderWithExpandedSources() async {
        let folder = URL(fileURLWithPath: "/folder", isDirectory: true)
        let child = folder.appendingPathComponent("child.nsp")
        let sibling = URL(fileURLWithPath: "/still-failing.nsp")
        runner.response = { _ in ("succeeded", ["sources": [
            self.row("folder", folder, "failed", needsKeys: false), self.row("sibling", sibling, "failed")]]) }
        model.importGames([folder, sibling], partialResults: true)
        await waitForImport()
        runner.response = { _ in ("succeeded", ["sources": [
            self.row("child", child, "imported"), self.row("sibling", sibling, "failed")]]) }
        model.retryImport()
        await waitForImport()
        XCTAssertEqual(model.importedSourceCount, 1)
        XCTAssertEqual(model.pendingSources.map(\.id), ["sibling"])
    }

    func testWelcomeMissingKeysContinuesWithExpandedSources() async {
        let folder = URL(fileURLWithPath: "/folder", isDirectory: true)
        let child = folder.appendingPathComponent("child.nsp")
        runner.response = { _ in ("keys_missing", ["sources": [self.row("child", child, "unprocessed")]]) }
        model.importGames([folder], partialResults: true)
        await waitForImport()
        XCTAssertFalse(model.showAddGames)
        XCTAssertFalse(model.showKeys)
        XCTAssertEqual(model.pendingImport, [child])
        runner.response = { _ in ("succeeded", ["sources": [self.row("child", child, "failed")]]) }
        model.importKeys(URL(fileURLWithPath: "/fixture.keys"))
        await waitForImport()
        XCTAssertEqual(runner.imports.last?["paths"] as? [String], [child.path])
        XCTAssertTrue(model.showKeys)
        XCTAssertFalse(model.showAddGames)
        XCTAssertEqual(ImportSheet(model: model, kind: .keys).page, .results)
    }

    private func row(_ id: String, _ path: URL, _ status: String, needsKeys: Bool = true,
                     diagnostic: String = "Fixture diagnostic") -> [String: Any] {
        ["id": id, "path": path.path, "name": path.lastPathComponent, "fileName": path.lastPathComponent,
         "status": status, "needsKeys": needsKeys, "code": status == "failed" ? "content_truncated" as Any : NSNull(),
         "reason": "Fixture reason", "diagnostic": diagnostic]
    }

    private func waitForImport() async {
        for _ in 0..<200 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
    }
}

private final class ImportRunner: JobProcessRunner {
    final class Handle: JobProcessHandle {
        var cancel: (() -> Void)?
        func terminate() { cancel?() }
    }

    var imports: [[String: Any]] = []
    var cancellations = 0
    var response: (([String: Any]) -> (state: String, result: [String: Any]))?

    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let url = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let isImport = request["operation"] as? String == "import"
        if isImport { imports.append(request) }
        let outcome = isImport ? (response?(request) ?? ("failed", [:])) : ("succeeded", ["games": []])
        let handle = Handle()
        func finish(_ state: String, _ result: [String: Any]) {
            let failed = state == "failed" || state == "keys_missing"
            var event: [String: Any] = ["schema": 1, "taskId": request["taskId"]!, "type": "result",
                "state": failed ? "failed" : state, "result": result, "message": failed ? "Fixture failure" : ""]
            if state == "keys_missing" { event["diagnostics"] = [["code": state]] }
            onLine(try! JSONSerialization.data(withJSONObject: event))
            onExit(state == "succeeded" ? 0 : state == "cancelled" ? 130 : 1)
        }
        if outcome.0 == "hold" {
            handle.cancel = {
                DispatchQueue.main.async {
                    self.cancellations += 1
                    finish("cancelled", [:])
                }
            }
        } else {
            DispatchQueue.main.async { finish(outcome.0, outcome.1) }
        }
        return handle
    }
}
