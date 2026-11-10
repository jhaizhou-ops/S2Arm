import XCTest
@testable import S2ArmLauncher

// 10-26 Spare-host：内存吃紧启动器失联，作业（独立进程）照跑；启动器重开时还活着的作业要接管、接着显示进度，不能一律改成「中断」。期望按场景手写
@MainActor final class JobAdoptTests: XCTestCase {
    private func lstart(_ pid: Int32) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath:"/bin/ps"); p.arguments = ["-o","lstart=","-p",String(pid)]
        let out = Pipe(); p.standardOutput = out; try? p.run(); p.waitUntilExit()
        return String(data:out.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)!.trimmingCharacters(in:.whitespacesAndNewlines)
    }

    func testJobAliveChecksPidAndStart() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(Store.jobAlive(Int(me), start:lstart(me)))
        XCTAssertFalse(Store.jobAlive(Int(me), start:"Thu Jan  1 00:00:00 1970"))   // 进程号被复用：起始时刻对不上
        XCTAssertFalse(Store.jobAlive(999_999, start:nil))
    }

    func testRecoverAdoptsLiveJobAndInterruptsDeadOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString)")
        let jobs = root.appendingPathComponent("logs/jobs"); try FileManager.default.createDirectory(at:jobs, withIntermediateDirectories:true)
        let me = ProcessInfo.processInfo.processIdentifier
        func write(_ id: String, pid: Int, start: String) throws {
            let obj: [String:Any] = ["schema":1,"id":id,"operation":"ipa","gameId":"g","state":"running","started":1.0,"pid":pid,"pidStart":start,"stage":"直连库"]
            try JSONSerialization.data(withJSONObject:obj).write(to:jobs.appendingPathComponent("\(id).json"))
        }
        try write("live", pid:Int(me), start:lstart(me))
        try write("dead", pid:999_999, start:"x")
        let store = Store(privateRoot:root)
        XCTAssertEqual(store.tasks.first { $0.id == "live" }?.state, "running")   // 接管：照旧在跑
        let dead = try JSONSerialization.jsonObject(with:Data(contentsOf:jobs.appendingPathComponent("dead.json"))) as! [String:Any]
        XCTAssertEqual(dead["state"] as? String, "interrupted")
        let live = try JSONSerialization.jsonObject(with:Data(contentsOf:jobs.appendingPathComponent("live.json"))) as! [String:Any]
        XCTAssertEqual(live["state"] as? String, "running")   // 记录没被改成中断
    }
}
