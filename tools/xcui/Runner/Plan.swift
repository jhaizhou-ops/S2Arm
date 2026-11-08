// 点按计划（纯解析，不碰 XCTest；Mac 上单测 tests/xcui_plan_test.sh）。
// 计划 = JSON：{"bundle": "<包名>", "steps": [步, …]}，步只有六种：
//   {"tap": "<无障碍标识>"}        点这个控件（等它出现，最多 timeout 秒，缺省 10）
//   {"tapxy": [x, y]}              在 App 窗口坐标（点）单指点一下
//   {"press": [x, y, 秒]}          单指按住这么久
//   {"slider": "<无障碍标识>", "to": 0~1}  把滑条拖到归一位置（等它出现，同 tap）
//   {"wait": 秒}                   等
//   {"type": "<无障碍标识>", "text": "文字"}  点中这个输入框再打字（等它出现，同 tap；系统键盘桥接验收：ios/textinput.m 的输入框标识 s2a.textinput.field）
// 每步可带 "timeout"（只对 tap / slider / type 有意义）。认不出的步整份拒绝（不半途执行）
import Foundation

struct XCUIPlan: Equatable {
    enum Step: Equatable { case tap(id: String, timeout: Double), slider(id: String, to: Double, timeout: Double), tapXY(x: Double, y: Double), press(x: Double, y: Double, seconds: Double), wait(Double), typeText(id: String, text: String, timeout: Double) }
    var bundle: String
    var steps: [Step]

    static func parse(_ data: Data) throws -> XCUIPlan {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw err("计划不是 JSON 对象") }
        guard let bundle = root["bundle"] as? String, !bundle.isEmpty else { throw err("缺 bundle（要附着的 App 包名）") }
        guard let raw = root["steps"] as? [[String: Any]], !raw.isEmpty else { throw err("缺 steps") }
        var steps: [Step] = []
        for (i, s) in raw.enumerated() {
            let to = (s["timeout"] as? NSNumber)?.doubleValue ?? 10
            if let id = s["tap"] as? String, !id.isEmpty { steps.append(.tap(id: id, timeout: to)) }
            else if let id = s["slider"] as? String, !id.isEmpty, let v = (s["to"] as? NSNumber)?.doubleValue, v >= 0, v <= 1 { steps.append(.slider(id: id, to: v, timeout: to)) }
            else if let p = s["tapxy"] as? [NSNumber], p.count == 2 { steps.append(.tapXY(x: p[0].doubleValue, y: p[1].doubleValue)) }
            else if let p = s["press"] as? [NSNumber], p.count == 3, p[2].doubleValue > 0 { steps.append(.press(x: p[0].doubleValue, y: p[1].doubleValue, seconds: p[2].doubleValue)) }
            else if let w = s["wait"] as? NSNumber, w.doubleValue >= 0 { steps.append(.wait(w.doubleValue)) }
            else if let id = s["type"] as? String, !id.isEmpty, let t = s["text"] as? String, !t.isEmpty { steps.append(.typeText(id: id, text: t, timeout: to)) }
            else { throw err("第 \(i + 1) 步认不出：\(s)") }
        }
        return XCUIPlan(bundle: bundle, steps: steps)
    }
    // xcodebuild 把 TEST_RUNNER_<名> 去掉前缀传给测试进程：计划按 base64 放 S2A_XCUI_PLAN（免得命令行转义）
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> XCUIPlan {
        guard let b = env["S2A_XCUI_PLAN"], let data = Data(base64Encoded: b) else { throw err("没有 S2A_XCUI_PLAN（base64 的计划 JSON）") }
        return try parse(data)
    }
    private static func err(_ m: String) -> NSError { NSError(domain: "S2AXCUI", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
}
