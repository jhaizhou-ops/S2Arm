import AppKit
import SwiftUI

/// Only logs owned by this task, inside the log directory (Store.logsRoot: <library>/logs, or <private>/logs before a library exists).
/// Journals and retry requests in logs/jobs/ are deliberately retained.
enum TaskLogFiles {
    static func validID(_ id:String) -> Bool {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"_-"))
        return !id.isEmpty && id.unicodeScalars.allSatisfy({safe.contains($0)})
    }
    static func urls(root:URL,task:TaskRecord,tasks:[TaskRecord]) -> [URL] {
        guard validID(task.id) else {return []}
        let directory = root.appendingPathComponent("logs")
        guard let info = try? directory.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]),
              info.isDirectory == true,info.isSymbolicLink != true,
              directory.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
              let files = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey]) else {return []}
        let owners = (tasks + [task]).sorted {$0.id.count > $1.id.count}
        return files.filter {url in
            let name = url.lastPathComponent
            guard let info = try? url.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey]),info.isSymbolicLink != true else {return false}
            let owner = owners.first {name == $0.id || name == $0.id+".log" || name.hasPrefix($0.id+"-") || name.hasPrefix($0.id+".")}
            guard owner?.id == task.id else {return false}
            if info.isDirectory == true {return name == task.id}
            return info.isRegularFile == true && (name.hasSuffix(".log") || name.hasSuffix(".events.jsonl") || name.hasSuffix(".progress.tsv"))
        }.sorted {$0.lastPathComponent < $1.lastPathComponent}
    }
}

extension Store {
    func canDeleteTaskLogs(_ task:TaskRecord) -> Bool {
        let current = tasks.first {$0.id == task.id} ?? task
        return !current.active && processes[task.id]?.isRunning != true && !TaskLogFiles.urls(root:logsRoot.deletingLastPathComponent(),task:current,tasks:tasks).isEmpty
    }
    /// Recycling is injectable so tests can use an isolated, recoverable archive.
    @discardableResult func trashTaskLogs(_ task:TaskRecord,recycle:(URL)throws->Void = {url in
        var destination:NSURL?
        try FileManager.default.trashItem(at:url,resultingItemURL:&destination)
    }) throws -> Int {
        let current = tasks.first {$0.id == task.id} ?? task
        let failure = { (message:String) in NSError(domain:"S2Arm.TaskLogs",code:1,userInfo:[NSLocalizedDescriptionKey:L(message)]) }
        guard !current.active,processes[current.id]?.isRunning != true else {throw failure("运行中的任务不能删除日志。")}
        guard TaskLogFiles.validID(current.id) else {throw failure("无法安全定位这项任务的日志。")}
        let jobRoot = jobsRoot
        let journal = jobRoot.appendingPathComponent(current.id+".json")
        guard jobRoot.resolvingSymlinksInPath().deletingLastPathComponent() == logsRoot.resolvingSymlinksInPath(),
              journal.resolvingSymlinksInPath().deletingLastPathComponent() == jobRoot.resolvingSymlinksInPath() else {throw failure("无法安全定位这项任务的日志。")}

        if FileManager.default.fileExists(atPath:journal.path) {
            guard let data = try? Data(contentsOf:journal),let record = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let state = record["state"] as? String else {throw failure("无法安全定位这项任务的日志。")}
            guard ["completed","failed","interrupted","cancelled"].contains(state) else {throw failure("运行中的任务不能删除日志。")}
            if let pid = record["pid"] as? Int,Self.jobAlive(pid,start:record["pidStart"] as? String) {throw failure("运行中的任务不能删除日志。")}
        }
        let files = TaskLogFiles.urls(root:logsRoot.deletingLastPathComponent(),task:current,tasks:tasks)
        for file in files {
            // Recheck ownership immediately before moving each file; never follow a replaced link.
            guard TaskLogFiles.urls(root:logsRoot.deletingLastPathComponent(),task:current,tasks:tasks).contains(file) else {throw failure("无法安全定位这项任务的日志。")}
            try recycle(file)
        }
        return files.count
    }
    func deleteTaskLogs(_ task:TaskRecord) {
        notice = nil
        do {
            if try trashTaskLogs(task) > 0 {notice = "日志已移到废纸篓"}
            else {notice = "暂无可删除的日志"}
        } catch {
            let message = "删除日志未完成，请检查权限后重试。"
            self.error = message
            errorDiagnostic = nativeDiagnostic(code:"logs_delete_failed",summary:message,detail:error.localizedDescription)
        }
    }
}

struct TaskLogDeleteButton:View {
    @EnvironmentObject var store:Store
    let task:TaskRecord
    @State private var confirm = false
    var body:some View {
        Button(role:.destructive) {confirm=true} label:{Image(systemName:"trash")}
            .buttonStyle(.borderless).controlSize(.small)
            .disabled(!store.canDeleteTaskLogs(task))
            .accessibilityLabel(L("删除日志…"))
            .help(L(store.canDeleteTaskLogs(task) ? "删除日志…" : "暂无可删除的日志"))
            .alert(L("将这项任务的日志移到废纸篓？"),isPresented:$confirm) {
                Button(L("取消"),role:.cancel) {}
                Button(L("移到废纸篓"),role:.destructive) {store.deleteTaskLogs(task)}
            } message:{Text(L("任务记录、编译产物和存档保留。可从废纸篓恢复日志。"))}
    }
}
