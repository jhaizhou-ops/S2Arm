// S2Arm（不是上游文件）：Switch 2 Pro 连接状态。启动并监看启动器旁的 S2ArmNS2Connection 进程（独占蓝牙连接，游戏经本机通道读输入），
//   持久化「开启 S2Arm 时自动连接」「关闭游戏后自动断开」两个开关（docs/mac-switch2-pro.md）。
//   另：系统蓝牙已连的一代 Joy-Con / Pro（含澳加狮等以 057e 出现的第三方）也反映到顶栏显示——游戏宿主走 HID，不必再点「连接手柄」。
import AppKit
import Combine
import Foundation
import IOBluetooth

@MainActor
final class NS2LauncherController: ObservableObject {
    enum Phase: Equatable {
        case off, starting, scanning, connecting, initializing, ready, failed, handedOff
    }

    @Published private(set) var autoConnectOnOpen: Bool
    @Published private(set) var disconnectAfterGame: Bool
    @Published private(set) var phase: Phase = .off
    @Published private(set) var detail = ""
    @Published private(set) var deviceName = "Switch 2 Pro"
    /// 系统蓝牙侧已连接的一代手柄摘要（与 NS2 BLE 通道无关）；空串表示没有。
    @Published private(set) var systemPadSummary = ""

    private let defaults: UserDefaults
    let socketURL: URL
    private var process: Process?
    private var output: Pipe?
    private var buffer = Data()
    private var intentionalStop = false
    private var systemPadTimer: Timer?
    private var ns2Detail = ""
    private var ns2DeviceName = "Switch 2 Pro"

    init(socketURL: URL) {
        self.socketURL = socketURL
        defaults = UserDefaults(suiteName: "org.s2arm.macos.game") ?? .standard
        autoConnectOnOpen = defaults.object(forKey: "S2AMacNS2AutoConnectOnOpen") as? Bool ?? false
        disconnectAfterGame = defaults.object(forKey: "S2AMacNS2DisconnectAfterGame") as? Bool ?? false
        refreshSystemPads()
        systemPadTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemPads() }
        }
        if let systemPadTimer {
            RunLoop.main.add(systemPadTimer, forMode: .common)
        }
    }

    deinit {
        systemPadTimer?.invalidate()
    }

    /// 顶栏 / 弹窗状态：NS2 通道优先；通道空闲时若系统已连 Joy-Con/Pro，显示为已连接。
    var buttonStatus: String {
        switch phase {
        case .ready: return "已连接"
        case .starting: return "启动中"
        case .scanning: return "搜索中"
        case .connecting, .initializing: return "连接中"
        case .failed:
            return systemPadSummary.isEmpty ? "未连接" : "已连接"
        case .handedOff: return "游戏使用中"
        case .off:
            return systemPadSummary.isEmpty ? "未连接" : "已连接"
        }
    }

    var buttonColor: NSColor {
        switch phase {
        case .ready: return .systemGreen
        case .starting, .scanning, .connecting, .initializing: return .systemOrange
        case .failed:
            return systemPadSummary.isEmpty ? .systemRed : .systemGreen
        case .handedOff: return .secondaryLabelColor
        case .off:
            return systemPadSummary.isEmpty ? .secondaryLabelColor : .systemGreen
        }
    }

    var hasConnectionProcess: Bool { process != nil }

    /// 弹窗标题用的设备名：NS2 已连/连接中用 NS2 名；否则用系统手柄摘要。
    var displayDeviceName: String {
        switch phase {
        case .ready, .handedOff, .starting, .scanning, .connecting, .initializing:
            return deviceName
        case .off, .failed:
            return systemPadSummary.isEmpty ? deviceName : systemPadSummary
        }
    }

    func startIfEnabled() {
        refreshSystemPads()
        guard autoConnectOnOpen else {
            phase = .off
            applyDisplayDetail()
            return
        }
        connectManually()
    }

    func setAutoConnectOnOpen(_ value: Bool) {
        autoConnectOnOpen = value
        defaults.set(value, forKey: "S2AMacNS2AutoConnectOnOpen")
    }

    func setDisconnectAfterGame(_ value: Bool) {
        disconnectAfterGame = value
        defaults.set(value, forKey: "S2AMacNS2DisconnectAfterGame")
    }

    func connectManually() {
        guard process == nil else { return }
        startProcess()
    }

    func disconnectManually() {
        stopProcess()
        phase = .off
        ns2Detail = "Switch 2 Pro 通道已断开。系统蓝牙手柄不受影响。"
        applyDisplayDetail()
    }

    func retry() {
        guard process != nil else { connectManually(); return }
        disconnectManually()
        connectManually()
    }

    /// 通道路径固定，开局时手柄还没连也照样交给游戏：游戏没接上时每秒重试，玩家开局后再连手柄，游戏也会接回
    ///   （以前没连接程序就不给，游戏开着时再连手柄，游戏这边一直没反应）。连接本身始终留在 S2Arm 的连接程序内。
    func relaySocketForGame() -> String? {
        socketURL.path
    }

    func gameDidStart() {
        guard process != nil else {
            refreshSystemPads()
            return
        }
        phase = .handedOff
        ns2Detail = "游戏正在使用 Switch 2 Pro；关闭游戏后连接会保留。"
        applyDisplayDetail()
    }

    func gameDidExit() {
        guard process != nil else {
            phase = .off
            applyDisplayDetail()
            return
        }
        if disconnectAfterGame {
            stopProcess()
            phase = .off
            ns2Detail = "游戏已关闭，已按设置断开 Switch 2 Pro。"
            applyDisplayDetail()
        } else if phase == .handedOff {
            phase = .ready
            ns2Detail = "\(ns2DeviceName) 仍保持连接，可以继续使用。"
            deviceName = ns2DeviceName
            applyDisplayDetail()
        }
    }

    func shutdown() {
        systemPadTimer?.invalidate()
        systemPadTimer = nil
        stopProcess()
    }

    private func startProcess() {
        guard let helper = helperURL else {
            phase = .failed
            ns2Detail = "找不到启动器的手柄连接组件。"
            applyDisplayDetail()
            return
        }
        phase = .starting
        ns2Detail = "正在启动蓝牙连接。首次使用时，请在 macOS 提示中允许。"
        ns2DeviceName = "Switch 2 Pro"
        deviceName = ns2DeviceName
        applyDisplayDetail()
        buffer.removeAll(keepingCapacity: true)
        intentionalStop = false

        let task = Process()
        let pipe = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["S2A_NS2_DEFAULTS_SUITE"] = "org.s2arm.macos.game"
        environment["S2A_NS2_SOCKET"] = socketURL.path
        task.executableURL = helper
        task.environment = environment
        task.standardOutput = pipe
        task.standardError = pipe
        process = task
        output = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        task.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.process = nil
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil
                if !self.intentionalStop {
                    self.phase = .failed
                    self.ns2Detail = "连接程序已停止，请手动重新连接。"
                    self.applyDisplayDetail()
                }
            }
        }
        do {
            try task.run()
        } catch {
            process = nil
            output = nil
            phase = .failed
            ns2Detail = error.localizedDescription
            applyDisplayDetail()
        }
    }

    private func stopProcess() {
        intentionalStop = true
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        guard let task = process else { return }
        process = nil
        task.terminationHandler = nil
        if task.isRunning { task.terminate(); task.waitUntilExit() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let code = (object["status"] as? NSNumber)?.intValue else { continue }
            apply(status: code, object)
        }
    }

    private func apply(status code: Int, _ object: [String: Any]) {
        if let name = object["name"] as? String, !name.isEmpty {
            ns2DeviceName = name
            deviceName = name
        }
        switch code {
        case 0:
            phase = .starting
            ns2Detail = "正在启动蓝牙连接。"
        case 1:
            phase = .scanning
            ns2Detail = "正在搜索手柄。请按一下手柄；未出现时长按顶部 SYNC。"
        case 2:
            phase = .connecting
            ns2Detail = "已找到手柄，正在连接。"
        case 3:
            phase = .initializing
            ns2Detail = "已连接，正在读取校准资料。"
        case 4:
            phase = .ready
            if let battery = (object["battery"] as? NSNumber)?.intValue {
                ns2Detail = "\(ns2DeviceName) 已连接，电量约 \(battery * 10)%。关闭游戏后仍会保持连接。"
            } else {
                ns2Detail = "\(ns2DeviceName) 已连接。关闭游戏后仍会保持连接。"
            }
        case 5, 9:
            phase = .failed
            ns2Detail = "Switch 2 Pro 未连接。请唤醒后按 SYNC，再点「重新连接」。"
        case 6:
            phase = .failed
            ns2Detail = "蓝牙不可用，请检查 macOS 蓝牙权限。"
        case 7:
            phase = .failed
            ns2Detail = (object["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "连接失败，请重试。"
        case 8:
            if phase != .handedOff {
                phase = .failed
                ns2Detail = "连接已停止。"
            }
        default:
            break
        }
        applyDisplayDetail()
    }

    private func refreshSystemPads() {
        let summary = Self.scanSystemPads()
        let changed = summary != systemPadSummary
        systemPadSummary = summary
        if changed || phase == .off || phase == .failed {
            applyDisplayDetail()
        }
    }

    private func applyDisplayDetail() {
        switch phase {
        case .ready, .handedOff, .starting, .scanning, .connecting, .initializing:
            detail = ns2Detail
            deviceName = ns2DeviceName
        case .off, .failed:
            if !systemPadSummary.isEmpty {
                deviceName = systemPadSummary
                let ns2Note: String
                if phase == .failed, !ns2Detail.isEmpty {
                    ns2Note = "（Switch 2 Pro 通道：" + ns2Detail + "）"
                } else {
                    ns2Note = "上方「连接手柄」仅用于 Switch 2 Pro 专用通道；一代 Joy-Con / 澳加狮等系统蓝牙手柄无需再连。"
                }
                detail = "\(systemPadSummary) 已通过系统蓝牙连接，可直接开始游戏。" + ns2Note
            } else {
                deviceName = "Switch 2 Pro"
                detail = ns2Detail.isEmpty
                    ? "手柄未连接。系统蓝牙 Joy-Con / Pro 连上后会显示在这里；Switch 2 Pro 也可点上方手动连接。"
                    : ns2Detail
            }
        }
        objectWillChange.send()
    }

    /// 读 macOS 已配对且当前已连接的一代手柄名（Joy-Con / Pro Controller；澳加狮等第三方常以此名出现）。
    private static func scanSystemPads() -> String {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        var left = false, right = false, pro = false
        var otherNames: [String] = []
        for device in paired where device.isConnected() {
            let name = (device.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            if lower.contains("joy-con") && (lower.contains("(l)") || lower.contains("left") || name.contains("左")) {
                left = true
            } else if lower.contains("joy-con") && (lower.contains("(r)") || lower.contains("right") || name.contains("右")) {
                right = true
            } else if lower.contains("pro controller") || lower.contains("switch pro") {
                pro = true
            } else if lower.contains("joy-con") {
                // 未标左右的 Joy-Con 仍算在场
                otherNames.append(name.isEmpty ? "Joy-Con" : name)
            } else if device.deviceClassMajor == 5 && device.deviceClassMinor == 2 {
                // Peripheral / Gamepad：无名第三方也展示
                otherNames.append(name.isEmpty ? "手柄" : name)
            }
        }
        var parts: [String] = []
        if left && right {
            parts.append("Joy-Con（左+右）")
        } else {
            if left { parts.append("Joy-Con（左）") }
            if right { parts.append("Joy-Con（右）") }
        }
        if pro { parts.append("Pro Controller") }
        for n in otherNames where !parts.contains(n) { parts.append(n) }
        return parts.joined(separator: " + ")
    }

    private var helperURL: URL? {
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("S2ArmNS2Connection")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
#if DEBUG
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let built = root.appendingPathComponent("build/S2ArmNS2Connection")
        if FileManager.default.isExecutableFile(atPath: built.path) { return built }
#endif
        return nil
    }
}
