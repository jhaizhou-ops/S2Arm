import XCTest
@testable import S2ArmLauncher

// 排队中点「取消任务」（11-01 联合开发者反馈）：排队任务没有进程，取消要把游戏移出队列、任务记「已从队列移除」，之后不会被 startNext 拉起
@MainActor final class QueueCancelTests: XCTestCase {
    func testCancellingQueuedTaskRemovesItFromQueue() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let store = Store(privateRoot:temp)
        let jobs = temp.appendingPathComponent("logs/jobs"); try FileManager.default.createDirectory(at:jobs, withIntermediateDirectories:true)
        let gid = "0100E95004038000"
        let rec = TaskRecord(id:"queued-"+gid, operation:"build", state:"queued", gameId:gid, started:Date().timeIntervalSince1970)
        try JSONEncoder().encode(rec).write(to:jobs.appendingPathComponent("queued-\(gid).json"))
        store.queue = [gid]; store.autoQueue = [gid]; store.tasks = [rec]
        store.cancel(rec)
        XCTAssertEqual(store.queue, [], "排队任务取消后移出队列（startNext 只从队列取，移出即不会再被拉起）")
        XCTAssertFalse(store.autoQueue.contains(gid))
        XCTAssertFalse(store.tasks.contains { $0.id == rec.id }, "任务卡不再留成灰着的 cancelling")
        let saved = try JSONDecoder().decode(TaskRecord.self, from:Data(contentsOf:jobs.appendingPathComponent("queued-\(gid).json")))
        XCTAssertEqual(saved.state, "cancelled"); XCTAssertEqual(saved.message, "已从队列移除")
    }
}
