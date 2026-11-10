import XCTest
import AppKit
import SwiftUI
@testable import S2ArmLauncher

/// #377：合成 plist 的期望来自出包元数据契约；ZIP 夹具走真实 unzip 与完成事件。
@MainActor final class PackModeTests: XCTestCase {
    // 现行计划（pack/jobs/milestones.py PLANS["ipa_dual"]）
    private let dualPlan = [Milestone(id: "unpack", label: "解包", purpose: "", expected: 15),
                            Milestone(id: "refresh", label: "改写与准备资源", purpose: "", expected: 60),
                            Milestone(id: "direct", label: "直连着色器库", purpose: "", expected: 560),
                            Milestone(id: "ipa", label: "编 App 与签名", purpose: "", expected: 150)]

    private func task(plan: [Milestone], current: String?, state: String = "running") -> TaskRecord {
        TaskRecord(id: "task", operation: "ipa", state: state, milestones: plan, milestone: current)
    }

    private func lane(_ groups: [PackStageGroup], _ id: String) -> PackStagePhase {
        groups.flatMap(\.phases).first { $0.id == id }!
    }

    private func evidence(_ info: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> PackGraphicsEvidence {
        PackGraphicsEvidenceReader.read(plist: try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0))
    }

    private func assertTitle(_ mode: PackGraphicsMode, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let previous = Localization.preference
        defer { Localization.preference = previous }
        Localization.preference = .simplifiedChinese
        XCTAssertEqual(mode.title, expected, file: file, line: line)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-packmode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ipa(in root: URL, info: [String: Any]) throws -> URL {
        let app = root.appendingPathComponent("Payload/X.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let url = root.appendingPathComponent("package with spaces.ipa")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", url.path, "Payload/X.app/Info.plist"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return url
    }

    func testDirectPlistCardText() throws {
        let e = try evidence(["S2AGraphicsMode": "direct"])
        XCTAssertEqual(e.mode, .direct)
        assertTitle(e.mode, "直连")
    }

    func testOldGenericPlistIsUnknown() throws {   // 包只出直连（11-07 拆掉通用模式）：旧的通用包按未知，不另画一档
        let e = try evidence(["S2AGraphicsMode": "generic", "S2AGraphicsModeReason": "没有可出库的键"])
        XCTAssertEqual(e.mode, .unknown)
        assertTitle(e.mode, "未知（这个包没有记录画面模式）")
    }

    func testMissingModePlistCardText() throws {
        let e = try evidence(["CFBundleName": "X"])
        assertTitle(e.mode, "未知（这个包没有记录画面模式）")
    }

    func testBinaryPlistMetadata() throws {
        let e = try evidence(["S2AGraphicsMode": "direct", "S2ADirectLibVersion": "b-chain",
                              "S2APackTime": "2026-10-25T09:00:00Z", "S2ABuildID": "test-build"], format: .binary)
        XCTAssertEqual(e.directLibraryVersion, "b-chain")
        XCTAssertEqual(e.packTime, "2026-10-25T09:00:00Z")
        XCTAssertEqual(e.buildID, "test-build")
    }

    func testUnknownAndWrongTypeModeNeverBecomeDirect() throws {
        for mode: Any in ["future", 42, true] {
            XCTAssertEqual(try evidence(["S2AGraphicsMode": mode]).mode, .unknown)
        }
    }

    func testMalformedPlistIsUnknown() {
        XCTAssertEqual(PackGraphicsEvidenceReader.read(plist: Data("not a plist".utf8)).mode, .unknown)
    }

    func testRealIPAExtractionWithSpacesInPath() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try ipa(in: root, info: ["S2AGraphicsMode": "direct", "S2ABuildID": "zip-fixture"])
        let e = PackGraphicsEvidenceReader.read(ipa: path)
        XCTAssertEqual(e.mode, .direct)
        XCTAssertEqual(e.buildID, "zip-fixture")
    }

    func testMissingAndCorruptIPANeverClaimMode() throws {
        XCTAssertEqual(PackGraphicsEvidenceReader.read(ipa: nil).mode, .unknown)
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("missing.ipa")
        XCTAssertEqual(PackGraphicsEvidenceReader.read(ipa: path).mode, .unknown)
        try Data("broken zip".utf8).write(to: path)
        XCTAssertEqual(PackGraphicsEvidenceReader.read(ipa: path).mode, .unknown)
    }

    func testIPAWithoutBundleInfoIsUnknown() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("other.txt"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        let path = root.appendingPathComponent("missing-info.ipa")
        process.arguments = ["-q", path.path, "other.txt"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(PackGraphicsEvidenceReader.read(ipa: path).mode, .unknown)
    }

    func testResultIPAPathPersistsAndDrivesCardAfterReload() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try ipa(in: root, info: ["S2AGraphicsMode": "direct", "S2ABuildID": "reload-fixture"])
        let store = Store(privateRoot: root.appendingPathComponent("private"))
        store.tasks = [.init(id: "fixture", operation: "ipa", state: "running")]
        XCTAssertEqual(store.packMode(for: store.tasks[0]), .unknown)
        store.event(["schema": 1, "taskId": "fixture", "type": "result", "state": "completed",
                     "result": ["outputPath": root.path, "ipa": path.path]], visible: true)
        let task = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(task.ipaPath, path.path)
        XCTAssertEqual(task.outputPath, root.path)
        store.persistTask(task)
        let restored = try JSONDecoder().decode(TaskRecord.self, from: Data(contentsOf: root.appendingPathComponent("private/logs/jobs/fixture.json")))
        XCTAssertEqual(restored.ipaPath, path.path)
        XCTAssertEqual(Store(privateRoot: root.appendingPathComponent("reloaded")).packMode(for: restored), .direct)
    }

    func testHistoricalTaskWithoutIPAPathIsUnknown() throws {
        let task = try JSONDecoder().decode(TaskRecord.self, from: Data(#"{"id":"old","operation":"ipa","state":"completed","outputPath":"/tmp/old"}"#.utf8))
        XCTAssertNil(task.ipaPath)
        XCTAssertEqual(Store(privateRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).packMode(for: task), .unknown)
    }

    func testStageStripFollowsCurrentPlan() {
        let groups = PackStagePlan.groups(for: task(plan: dualPlan, current: "direct"))
        XCTAssertEqual(groups.map(\.id), ["unpack", "prep", "direct", "sign"])
        XCTAssertEqual(groups[2].phases.map(\.id), ["direct"])
        XCTAssertEqual(lane(groups, "direct").label, "直连库")
        XCTAssertEqual(lane(groups, "unpack").state, .done)
        XCTAssertEqual(lane(groups, "prep").state, .done)
        XCTAssertEqual(lane(groups, "direct").state, .running)
        XCTAssertEqual(lane(groups, "direct").detail, "直连着色器库")
        XCTAssertEqual(lane(groups, "direct").fill, 0.05, accuracy: 1e-9)   // 没有真实完成数：只留一点颜色，不编比例
        XCTAssertEqual(lane(groups, "sign").state, .pending)
        XCTAssertEqual(lane(groups, "sign").label, "编 App 与签名")
    }

    func testExplicitProfileMilestoneGetsOwnLane() {
        var plan = dualPlan
        plan.insert(Milestone(id: "direct_profile", label: "推导配置", purpose: "", expected: 10), at: 2)
        let groups = PackStagePlan.groups(for: task(plan: plan, current: "direct_profile"))
        XCTAssertEqual(lane(groups, "profile").state, .running)
        XCTAssertEqual(lane(groups, "direct").label, "直连库")
    }

    func testRefreshMilestoneDrivesPrepLane() {
        let groups = PackStagePlan.groups(for: task(plan: dualPlan, current: "refresh"))
        XCTAssertEqual(lane(groups, "prep").state, .running)
        XCTAssertEqual(lane(groups, "direct").state, .pending)
    }

    func testPlanWithoutDirectDoesNotInventIt() {
        let plan = dualPlan.filter { $0.id != "direct" }
        let groups = PackStagePlan.groups(for: task(plan: plan, current: "refresh"))
        XCTAssertEqual(lane(groups, "direct").state, .unused(nil))
        XCTAssertFalse(groups.contains { $0.id == "profile" })
    }

    func testCompletedMilestonesReportExecutionWithoutGuessingPackageContents() {
        let groups = PackStagePlan.groups(for: task(plan: dualPlan, current: "ipa", state: "completed"))
        for phase in groups.flatMap(\.phases) { XCTAssertEqual(phase.state, .done) }
    }

    func testAllCardOutcomesRenderInBothLanguages() throws {
        let previous = Localization.preference
        defer { Localization.preference = previous }
        for language in [AppLanguage.simplifiedChinese, .english] {
            Localization.preference = language
            for mode in [PackGraphicsMode.direct, .unknown] {
                let view = NSHostingView(rootView: PackModeCard(mode: mode).frame(width: 640))
                view.frame = NSRect(x: 0, y: 0, width: 640, height: 180)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                XCTAssertGreaterThan(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).count, 0)
            }
        }
    }
}
