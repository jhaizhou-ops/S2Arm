import AppKit
import XCTest
@testable import S2ArmLauncher

@MainActor final class TaskLogTests:XCTestCase {
    private func fixture() throws -> (URL,Store,TaskRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-task-logs-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("logs"),withIntermediateDirectories:true)
        let store = Store(privateRoot:root)
        let task = TaskRecord(id:"fixture-task",operation:"build",state:"completed")
        store.tasks = [task]
        return (root,store,task)
    }
    private func write(_ value:String,to url:URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try value.write(to:url,atomically:true,encoding:.utf8)
    }
    func testOnlyOwnedLogsAreRecycledAndRecordsOutputsAndSavesRemain() throws {
        let (root,store,task) = try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let other = TaskRecord(id:task.id+"-other",operation:"build",state:"completed");store.tasks.append(other)
        let logs = root.appendingPathComponent("logs")
        let owned = [task.id+".log",task.id+"-failure.log",task.id+".progress.tsv",task.id+"-ipa.events.jsonl"]
        for name in owned {try write(name,to:logs.appendingPathComponent(name))}
        try write("nested",to:logs.appendingPathComponent(task.id+"/build.log"))
        let kept = ["logs/jobs/\(task.id).json","logs/jobs/\(task.id).request.json","logs/jobs/\(task.id).events.jsonl","out/game.ipa","saves/data","logs/\(other.id)-build.log","logs/shared.log"]
        for name in kept {try write(name.hasSuffix(task.id+".json") ? "{\"state\":\"completed\"}" : "keep",to:root.appendingPathComponent(name))}
        let archive = root.appendingPathComponent("recoverable");try FileManager.default.createDirectory(at:archive,withIntermediateDirectories:true)
        XCTAssertTrue(store.canDeleteTaskLogs(task))
        let count = try store.trashTaskLogs(task) {try FileManager.default.moveItem(at:$0,to:archive.appendingPathComponent($0.lastPathComponent))}
        XCTAssertEqual(count,5)
        XCTAssertFalse(store.canDeleteTaskLogs(task))
        XCTAssertEqual(store.tasks.map(\.id),[task.id,other.id])
        for name in kept {XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(name).path),name)}
        for name in owned {XCTAssertEqual(try String(contentsOf:archive.appendingPathComponent(name),encoding:.utf8),name)}
    }
    func testActiveAndStaleTaskViewsCannotDeleteLogs() throws {
        let (root,store,task) = try fixture();defer {try? FileManager.default.removeItem(at:root)}
        try write("log",to:root.appendingPathComponent("logs/\(task.id).log"))
        for state in ["running","queued","cancelling"] {
            store.tasks[0].state = state
            XCTAssertFalse(store.canDeleteTaskLogs(task))
            XCTAssertThrowsError(try store.trashTaskLogs(task) {_ in XCTFail("must not recycle")})
        }
    }
    func testLiveWorkerJournalOverridesTerminalView() throws {
        let (root,store,task) = try fixture();defer {try? FileManager.default.removeItem(at:root)}
        try write("log",to:root.appendingPathComponent("logs/\(task.id).log"))
        try write("{\"state\":\"running\"}",to:root.appendingPathComponent("logs/jobs/\(task.id).json"))
        XCTAssertThrowsError(try store.trashTaskLogs(task) {_ in XCTFail("must not recycle")})
        try write("{\"state\":\"completed\",\"pid\":\(ProcessInfo.processInfo.processIdentifier)}",to:root.appendingPathComponent("logs/jobs/\(task.id).json"))
        XCTAssertThrowsError(try store.trashTaskLogs(task) {_ in XCTFail("live PID must not recycle")})
        try write("{broken",to:root.appendingPathComponent("logs/jobs/\(task.id).json"))
        XCTAssertThrowsError(try store.trashTaskLogs(task) {_ in XCTFail("unreadable state must not recycle")})
    }
    func testExternalLinksAndInvalidIDsAreNotDeletionTargets() throws {
        let (root,store,task) = try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let outside = root.appendingPathComponent("outside.log");try write("keep",to:outside)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("logs/\(task.id)-external.log"),withDestinationURL:outside)
        XCTAssertTrue(TaskLogFiles.urls(root:root,task:task,tasks:store.tasks).isEmpty)
        let invalid = TaskRecord(id:"../outside",operation:"build",state:"completed")
        XCTAssertThrowsError(try store.trashTaskLogs(invalid) {_ in XCTFail("invalid ID")})
        try FileManager.default.removeItem(at:root.appendingPathComponent("logs"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("external"),withIntermediateDirectories:true)
        try write("keep",to:root.appendingPathComponent("external/\(task.id).log"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("logs"),withDestinationURL:root.appendingPathComponent("external"))
        XCTAssertFalse(store.canDeleteTaskLogs(task))
        XCTAssertEqual(try String(contentsOf:outside,encoding:.utf8),"keep")
    }
    func testRecycleFailurePropagatesAndDoesNotRemoveRecord() throws {
        let (root,store,task) = try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let log = root.appendingPathComponent("logs/\(task.id).log");try write("keep",to:log)
        XCTAssertThrowsError(try store.trashTaskLogs(task) {_ in throw CocoaError(.fileWriteNoPermission)})
        XCTAssertTrue(FileManager.default.fileExists(atPath:log.path));XCTAssertEqual(store.tasks.count,1)
    }
    func testLegacyMessagesUseCompilationTerminologyWithoutChangingJournalText() {
        let previous = Localization.preference;defer {Localization.preference=previous}
        Localization.preference = .simplifiedChinese
        let task = TaskRecord(id:"fixture",operation:"build",state:"completed",message:"打包完成，可以启动了。")
        XCTAssertEqual(task.message,"打包完成，可以启动了。")
        XCTAssertEqual(task.title,"编译游戏")
        XCTAssertEqual(L(task.message!),"编译完成，可以启动了。")
        XCTAssertEqual(L("开始打包"),"开始编译")
        Localization.preference = .english
        XCTAssertEqual(L("编译任务"),"Compilation tasks")
        XCTAssertEqual(L("开始打包"),"Start Compiling")
    }
}
