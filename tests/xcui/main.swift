// tests/xcui_plan_test.sh 的驱动：Plan.swift 在 Mac 上直接编，期望按计划格式手写
import Foundation
var bad = 0
func ck(_ ok: Bool, _ what: String) { print(ok ? "通 \(what)" : "不通 \(what)"); if !ok { bad += 1 } }
func p(_ s: String) -> XCUIPlan? { try? XCUIPlan.parse(Data(s.utf8)) }
let good = p(#"{"bundle":"io.s2arm.mk8d","steps":[{"tap":"settings.S2ADockedMode"},{"tap":"settings.done","timeout":3},{"tapxy":[100,200.5]},{"press":[1,2,1.5]},{"wait":2}]}"#)
ck(good == XCUIPlan(bundle: "io.s2arm.mk8d", steps: [.tap(id: "settings.S2ADockedMode", timeout: 10), .tap(id: "settings.done", timeout: 3), .tapXY(x: 100, y: 200.5), .press(x: 1, y: 2, seconds: 1.5), .wait(2)]),
   "五种写法按序解出、tap 缺省等 10 秒")
ck(p(#"{"bundle":"b","steps":[{"slider":"settings.S2AResolutionScale","to":1},{"slider":"s","to":0.25,"timeout":4}]}"#) == XCUIPlan(bundle: "b", steps: [.slider(id: "settings.S2AResolutionScale", to: 1, timeout: 10), .slider(id: "s", to: 0.25, timeout: 4)]),
   "滑条步解出、缺省等 10 秒")
ck(p(#"{"bundle":"b","steps":[{"slider":"s"}]}"#) == nil, "滑条缺 to 拒收")
ck(p(#"{"bundle":"b","steps":[{"slider":"s","to":1.5}]}"#) == nil, "滑条位置超出 0~1 拒收")
ck(p(#"{"steps":[{"wait":1}]}"#) == nil, "缺 bundle 拒收")
ck(p(#"{"bundle":"x","steps":[]}"#) == nil, "空步拒收")
ck(p(#"{"bundle":"x","steps":[{"wait":1},{"swipe":[1,2]}]}"#) == nil, "认不出的步整份拒收（不半途执行）")
ck(p(#"{"bundle":"x","steps":[{"tapxy":[1]}]}"#) == nil, "坐标不是两个数拒收")
ck(p(#"{"bundle":"x","steps":[{"press":[1,2,0]}]}"#) == nil, "按住 0 秒拒收")
ck(p(#"{"bundle":"b","steps":[{"type":"s2a.textinput.field","text":"李雷ab"},{"type":"f","text":"x","timeout":3}]}"#) == XCUIPlan(bundle: "b", steps: [.typeText(id: "s2a.textinput.field", text: "李雷ab", timeout: 10), .typeText(id: "f", text: "x", timeout: 3)]),
   "打字步解出（中文原样）、缺省等 10 秒")
ck(p(#"{"bundle":"b","steps":[{"type":"f"}]}"#) == nil, "打字缺 text 拒收")
let env = ["S2A_XCUI_PLAN": Data(#"{"bundle":"b","steps":[{"wait":0}]}"#.utf8).base64EncodedString()]
ck((try? XCUIPlan.fromEnvironment(env))?.bundle == "b", "从 S2A_XCUI_PLAN（base64）读计划")
ck((try? XCUIPlan.fromEnvironment([:])) == nil, "没有 S2A_XCUI_PLAN 报错")
exit(bad == 0 ? 0 : 1)
