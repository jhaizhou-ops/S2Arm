// 整屏截图认字（tools/sysdialog.sh 用）：screen_text <png> → 每行一段认出的文字（简中 + 英文，系统 Vision 框架，离线、不联网）
import AppKit
import Vision

guard CommandLine.arguments.count == 2, let img = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { FileHandle.standardError.write("用法：screen_text <png>（读不出图）\n".data(using: .utf8)!); exit(2) }
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.recognitionLanguages = ["zh-Hans", "en-US"]
do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { FileHandle.standardError.write("认字失败：\(error)\n".data(using: .utf8)!); exit(1) }
for o in req.results ?? [] { if let s = o.topCandidates(1).first?.string { print(s) } }
