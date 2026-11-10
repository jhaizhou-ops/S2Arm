import XCTest
import SwiftUI
import AppKit
@testable import S2ArmLauncher

@MainActor final class SaveManagementTests: XCTestCase {
    func waitForSave(_ store: Store) async throws {
        for _ in 0..<400 where store.executionBusy { try await Task.sleep(for:.milliseconds(25)) }
        XCTAssertFalse(store.executionBusy,store.error ?? "save worker did not exit")
    }

    func testActualWorkersBackUpInspectRestoreAndKeepPreviousSave() async throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer {try? FileManager.default.removeItem(at:temp)}
        let library=temp.appendingPathComponent("library"), user="00000000000000010000000000000000", gid="0100000000000000"
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        let game=Game(id:gid,name:"Synthetic save fixture",display:"1.0",packages:[],hidden:false)
        try JSONSerialization.data(withJSONObject:["schema":1,"id":"fixture-library"]).write(to:library.appendingPathComponent(".s2arm-library.json"))
        try JSONSerialization.data(withJSONObject:["schema":1,"games":[["id":gid,"name":game.name,"display":"1.0","hidden":false,"packages":[]]]]).write(to:library.appendingPathComponent("catalog.json"))
        // 游戏库结构 v2（pack/jobs/layout.py）：每款一个文件夹，game.json 认游戏号，存档在它的 saves/；布局标记写好，作业不再迁移
        let folder=library.appendingPathComponent("games/Synthetic save fixture")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["schema":1,"id":gid]).write(to:folder.appendingPathComponent("game.json"))
        try JSONSerialization.data(withJSONObject:["version":2,"games":[String]()]).write(to:library.appendingPathComponent(".s2arm-layout.json"))
        let root=folder.appendingPathComponent("saves")
        let progress=root.appendingPathComponent("bis/user/save/0000000000000001/0/progress.bin")
        try FileManager.default.createDirectory(at:progress.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("checkpoint-one".utf8).write(to:progress)
        // Synthetic committed IMKV index (LibHac SaveDataAttribute/IndexerValue).
        let index=root.appendingPathComponent("bis/system/save/8000000000000000/0/imkvdb.arc")
        try FileManager.default.createDirectory(at:index.deletingLastPathComponent(),withIntermediateDirectories:true)
        var indexBytes=Data([0x49,0x4d,0x4b,0x56,0,0,0,0,3,0,0,0])
        let otherUser="00000000000000020000000000000000"
        for saveId: UInt8 in 1...3 {
            indexBytes.append(contentsOf:[0x49,0x4d,0x45,0x4e,0x40,0,0,0,0x40,0,0,0])
            var entry=Data(repeating:0,count:128)
            entry[7]=1;entry[8]=saveId == 3 ? 0 : saveId
            entry[0x20]=saveId == 3 ? 3 : 1;entry[0x40]=saveId;entry[0x58]=1
            indexBytes.append(entry)
            let directory=root.appendingPathComponent(String(format:"bis/user/save/%016x/0",Int(saveId)))
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        }
        try indexBytes.write(to:index)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("system"),withIntermediateDirectories:true)
        let currentUser="00000000000000090000000000000000"
        try JSONSerialization.data(withJSONObject:["last_opened":currentUser,"profiles":[["user_id":currentUser]]]).write(to:root.appendingPathComponent("system/Profiles.json"))
        let store=Store(privateRoot:temp.appendingPathComponent("private"))
        store.preferences.pythonPath=ProcessInfo.processInfo.environment["S2A_PYTHON"]
        store.preferences.library=library.path;store.preferences.libraryId="fixture-library"
        store.games=[game]
        XCTAssertFalse(store.hasImportedKeys)
        XCTAssertFalse(store.environmentReady)
        let backup=temp.appendingPathComponent("progress.s2asave")
        var output: [String:Any]?
        XCTAssertNotNil(store.saveJob("saveBackup",game:game,path:backup) { output=$0 })
        try await waitForSave(store)
        let saved=URL(fileURLWithPath:try XCTUnwrap(output?["outputPath"] as? String))
        XCTAssertEqual(saved.resolvingSymlinksInPath(),backup.resolvingSymlinksInPath(),store.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath:backup.path))
        try Data("checkpoint-two".utf8).write(to:progress)
        var preview: SavePreview?
        store.saveJob("saveInspect",game:game,path:backup) { preview=Store.decode(SavePreview.self,$0) }
        try await waitForSave(store)
        let checked=try XCTUnwrap(preview,store.error ?? "")
        XCTAssertEqual(checked.manifest.users.active,user)
        XCTAssertEqual(checked.manifest.users.ids,[user,otherUser])
        XCTAssertFalse(checked.manifest.users.ids.contains(currentUser))
        XCTAssertFalse(checked.manifest.users.ids.contains(String(repeating:"0",count:32)))
        output=nil
        store.saveJob("saveRestore",game:game,path:backup,preview:checked) { output=$0 }
        try await waitForSave(store)
        XCTAssertEqual(try Data(contentsOf:progress),Data("checkpoint-one".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath:try XCTUnwrap(output?["previousBackup"] as? String)))
        XCTAssertEqual(Set(store.visibleTasks.map(\.operation)),["saveBackup","saveInspect","saveRestore"])
        store.retry(try XCTUnwrap(store.tasks.first))
        XCTAssertEqual(store.saveManagerGame?.id,gid)
        XCTAssertFalse(store.executionBusy) // Retry asks for inspection/confirmation again.
    }

    func testSaveJobsRespectExecutionAndQueueWithoutSDKRequirements() throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temp)}
        let store=Store(privateRoot:temp)
        let game=Game(id:"0100000000000000",name:"Fixture",display:"",packages:[],hidden:false)
        store.preferences.library=temp.appendingPathComponent("library").path
        XCTAssertTrue(store.canManageSaves)
        store.executionTask="running-game"
        XCTAssertNil(store.saveJob("saveBackup",game:game) { _ in XCTFail("must not run") })
        store.executionTask=nil;store.queue=[game.id]
        XCTAssertNil(store.saveJob("saveRestore",game:game) { _ in XCTFail("must not run") })
        XCTAssertTrue(store.processes.isEmpty)
    }

    // 玩家点「出 iPhone 包」时后台自动 Mac 准备让位（10-26 维护者定）：只被自动准备占着才让；玩家自己点的任务在跑 / 排队就不让
    func testIPhonePackPreemptsOnlyAutomaticPreparation() throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temp)}
        let store=Store(privateRoot:temp)
        store.executionTask="auto-1"; store.autoBuildTask="auto-1"; store.queue=["g2"]; store.autoQueue=["g2"]
        let plan=try XCTUnwrap(store.ipaYieldPlan()); XCTAssertEqual(plan.stop,"auto-1"); XCTAssertEqual(plan.drop,["g2"])
        store.autoBuildTask=nil   // 玩家自己点的 Mac 准备在跑
        XCTAssertNil(store.ipaYieldPlan())
        store.executionTask=nil; store.queue=["g3"]; store.autoQueue=[]   // 玩家自己排的
        XCTAssertNil(store.ipaYieldPlan())
        store.queue=[]   // 空闲：照常出包，不用让
        XCTAssertNil(store.ipaYieldPlan())
        store.queue=["g4"]; store.autoQueue=["g4"]   // 只有自动排队的：撤下、不用停进程
        let idle=try XCTUnwrap(store.ipaYieldPlan()); XCTAssertNil(idle.stop); XCTAssertEqual(idle.drop,["g4"])
        // 让位动作：在跑的自动准备记「让位中」、写明原因，iPhone 包挂起等它停，不弹错
        let game=Game(id:"0100000000000000",name:"Fixture",display:"",packages:[],hidden:false)
        store.queue=[]; store.autoQueue=[]; store.executionTask="auto-2"; store.autoBuildTask="auto-2"
        store.tasks=[TaskRecord(id:"auto-2",operation:"build",state:"running",gameId:"0100000000000001",started:0)]
        store.packIPhone(game)
        XCTAssertEqual(store.pendingIPA?.id,game.id); XCTAssertTrue(store.yieldedTasks.contains("auto-2"))
        XCTAssertEqual(store.yieldedGames,["0100000000000001"]); XCTAssertEqual(store.tasks.first?.message,Store.yieldMessage)
        XCTAssertNil(store.error)
    }

    // 社区存档「目录结构存疑」：后端 inspect 多一个 notice，界面在确认恢复前显示；旧后端没有这个字段也要能解
    func testSavePreviewNoticeIsOptionalShownBeforeRestoreAndNeverSentBack() throws {
        let notice="这份存档的目录结构不常见，导入时会按原样照搬。如果游戏读不到进度，请换一份存档。"
        let body:[String:Any]=[
            "manifest":["schema":1,"createdAt":"2026-10-27T00:00:00+00:00","game":["id":"0100000000000000","name":"Fixture","version":1],"users":["ids":[String](),"active":""]],
            "archiveSha256":String(repeating:"a",count:64),"targetFingerprint":String(repeating:"b",count:64),
            "previewLibraryId":"fixture-library","fileCount":1,"totalBytes":1,"notice":notice]
        let preview=try XCTUnwrap(Store.decode(SavePreview.self,body))
        XCTAssertEqual(preview.notice,notice)
        // notice 只是给人看的：恢复请求仍旧只带那三项校验值
        XCTAssertEqual(Set(preview.request.keys),["archiveSha256","targetFingerprint","previewLibraryId"])
        var legacy=body
        legacy.removeValue(forKey:"notice")
        let old=try XCTUnwrap(Store.decode(SavePreview.self,legacy))
        XCTAssertNil(old.notice)
        let previous=Localization.preference
        defer {Localization.preference=previous}
        Localization.preference = .english
        XCTAssertEqual(L(notice),"This save's folder structure is unusual; it is imported exactly as packed. If the game does not see your progress, try a different save.")
    }

    func testSaveManagementRendersInChineseAndEnglish() throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temp)}
        let store=Store(privateRoot:temp)
        let game=Game(id:"0100000000000000",name:"Fixture",display:"",packages:[],hidden:false)
        let previous=Localization.preference
        defer {Localization.preference=previous}
        for language in [AppLanguage.simplifiedChinese,.english] {
            Localization.preference=language
            let view=NSHostingView(rootView:SaveManagementView(game:game).environmentObject(store))
            view.frame=NSRect(x:0,y:0,width:680,height:680);view.layoutSubtreeIfNeeded()
            let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            XCTAssertNotNil(bitmap.representation(using:.png,properties:[:]))
        }
        Localization.preference = .english
        XCTAssertEqual(L("存档备份与恢复"),"Save backup and restoration")
        XCTAssertNotEqual(L("备份属于另一款游戏，已拒绝恢复。"),"备份属于另一款游戏，已拒绝恢复。")
    }

    func testSaveOwnershipRendersAccountAndDeviceOnlyBackups() throws {
        let previous=Localization.preference
        defer {Localization.preference=previous}
        for language in [AppLanguage.simplifiedChinese,.english] {
            Localization.preference=language
            for users in [SaveUsers(ids:[],active:""),SaveUsers(ids:[String(repeating:"1",count:32),String(repeating:"2",count:32)],active:String(repeating:"1",count:32))] {
                for appearance in [NSAppearance.Name.aqua,.darkAqua,.accessibilityHighContrastAqua,.accessibilityHighContrastDarkAqua] {
                    let view=NSHostingView(rootView:SaveOwnershipView(users:users).padding().frame(width:400))
                    view.appearance=NSAppearance(named:appearance)
                    view.frame=NSRect(x:0,y:0,width:400,height:120);view.layoutSubtreeIfNeeded()
                    let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    XCTAssertNotNil(bitmap.representation(using:.png,properties:[:]))
                }
            }
        }
        Localization.preference = .english
        XCTAssertEqual(L("存档所属用户"),"Save owners")
        XCTAssertEqual(L("仅含设备存档，不属于单个用户。"),"Device saves only; not tied to an individual user.")
    }
}

/// 审计 18:00 P0-3：Mac 存档回退失败与 iPhone 同一条规则——错误框认出 save_recovery 才给「仍要启动」，确认只放行那一款的下一次启动；存档页读出事务记录路径
@MainActor final class SaveRecoveryOverrideTests: XCTestCase {
    func testRecoveryFailureOffersOverrideForThatGameOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        let game = Game(id: "0100000000000001", name: "Fixture", display: "1.0", packages: [], hidden: false)
        store.games = [game]
        store.tasks = [TaskRecord(id: "t1", operation: "launch", state: "failed", gameId: game.id)]
        store.error = "存档恢复事务尚未完成"
        store.errorDiagnostic = store.nativeDiagnostic(code: "save_recovery", summary: "x", detail: "y")
        XCTAssertEqual(store.saveRecoveryGame?.id, game.id)
        XCTAssertNil(store.launchOptions(for: game.id)["overrideRecovery"], "没确认前不放行")
        store.recoveryOverride = game.id
        XCTAssertEqual(store.launchOptions(for: game.id)["overrideRecovery"] as? Bool, true)
        XCTAssertNil(store.launchOptions(for: "0100000000000002")["overrideRecovery"], "确认只管那一款")
        store.errorDiagnostic = store.nativeDiagnostic(code: "runtime_invalid", summary: "x", detail: "y")
        XCTAssertNil(store.saveRecoveryGame, "别的失败不给「仍要启动」")
    }
    func testCleanupWarningIsNotShownAsSuccess() {   // 审计 18:00 P2-32：事务没清完不打勾
        XCTAssertEqual(SaveManagementView.resultIcon(warns: true), "exclamationmark.triangle.fill")
        XCTAssertEqual(SaveManagementView.resultIcon(warns: false), "checkmark.circle")
    }
    func testStatusDecodesRecoveryFailurePathAndOldBackend() throws {
        let failed = try JSONDecoder().decode(SaveStatus.self, from: Data(#"{"hasSave":true,"fileCount":1,"totalBytes":2,"previousBackup":"","recovered":false,"recoveryFailed":"/lib/save-transactions/g.json"}"#.utf8))
        XCTAssertEqual(failed.recoveryFailed, "/lib/save-transactions/g.json")
        let old = try JSONDecoder().decode(SaveStatus.self, from: Data(#"{"hasSave":false,"fileCount":0,"totalBytes":0,"previousBackup":"","recovered":false}"#.utf8))
        XCTAssertNil(old.recoveryFailed)
    }
}
