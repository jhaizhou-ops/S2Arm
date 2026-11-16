// S2Arm（不是上游文件）：顶栏手柄按钮与弹窗：连接状态、手动连接 / 断开、持久化开关（收在齿轮选单）。
//   区块按连接通道分：Switch 2 区块只给 S2Arm 直连（controller），蓝牙区块只给系统蓝牙手柄（systems.pads）——
//   两条通道不同，Switch 2 区块的标题 / 状态不可借用蓝牙手柄的名字（#901 曾把系统手柄名写进 Switch 2 标题，DualSense 出现两次）
//
// 【方案建议：手机当手柄（Mobile），功能未做，给之后开发的人】
//   - 不另开首页面板：手机就是第三条输入通道，放在这个弹窗里，排在「蓝牙」区块下面，样式同其他区块
//     （小标头 Mobile / 手机、ControllerIcon(.mobile)、标题、StatusLine、整宽主按钮），不加卡中卡、色标或说明小字。
//   - 标题：一台写手机名，多台写数量（同蓝牙区块「N 个蓝牙手柄」）；状态行沿用 NS2LauncherController.Status 的词。
//   - 配对：主按钮「连接手机」→ 在按钮上弹 .popover 显示 QR 码（局域网地址 + 一次性配对码），手机扫码后打开手柄页面；
//     同一 Wi-Fi 用 Bonjour 找主机。连上后主按钮变「断开」；设定（如自动接受已配对手机）放进同样的齿轮选单，面板不变高。
//   - 玩家：每台手机是 PlayerAssignment.Unit 的一种新来源（如 .mobile(id)），完全走现有分配玩家流程——
//     连上时由 PlayerAssignment.reconcile 自动排进下一个空位，「分配玩家」里按手机上的按钮登记 / 换位、× 清空；
//     不写死手机是 P1 / P2 / P3，也不给手机保留玩家位。玩家列表用 ControllerIcon(.mobile)。
//   - 顶栏：三条通道合并看（任一通道连着 = 绿点「已连接」，见 NS2LauncherController.buttonStatus / title）。
//   - 上线前面板不显示 Mobile 区块，只预留 ControllerIcon.Glyph.mobile。
import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

struct Switch2ProConnectionPopover: View {
    @ObservedObject var controller: NS2LauncherController
    @ObservedObject var systems: SystemControllers
    let lang: String   // 界面语言代码（Lang.code）
    var onClose: () -> Void = {}   // 手柄 B 关面板（顶栏传进来）

    private func t(_ key: String) -> String { NS2LauncherController.text("s2arm.controller." + key, lang) }
    @Environment(\.padControls) private var padControls   // 界面导航（分配中把手柄按键送进来）
    @State private var keyMonitor: Any?   // 分配中收键盘按键（键盘登记成一位玩家）
    @State private var showSettings = false   // 齿轮选单
    @State private var pressKeyMonitor: Any?   // 认手柄：键盘按键让键盘那一位亮一下（不吞键）
    @State private var selectedPlayer = 0   // 玩家列表选中的一位（下面给非任天堂手柄的按键对应编辑）
    private var zh: Bool { lang.hasPrefix("zh") }
    private var currentPlayer: Int { controller.assignment.units.indices.contains(selectedPlayer) ? selectedPlayer : 0 }

    private func unitGlyph(_ unit: PlayerAssignment.Unit) -> ControllerIcon.Glyph {
        switch unit {
        case .pair: return .pairHead
        case .single(_, let kind), .whole(_, let kind): return ControllerIcon.player(kind: kind) ?? .unknown
        case .system(let name, _): return ControllerIcon.systemPlayer(systems.pads.first { $0.name == name }?.family ?? .other)
        case .keyboard: return .keyboard
        case let .gen1(_, side): return side == 0 ? .gen1LeftSideways : .gen1RightSideways
        case .gen1Pair: return .gen1Pair
        }
    }
    private func unitName(_ unit: PlayerAssignment.Unit) -> String {
        switch unit {
        case .pair: return NS2LauncherController.title(kind: 4, lang: lang)
        case .single(_, let kind), .whole(_, let kind): return NS2LauncherController.title(kind: kind, lang: lang)
        case .system(let name, _): return name
        case .keyboard: return t("keyboard")
        case let .gen1(_, side): return side == 0 ? "Joy-Con (L)" : "Joy-Con (R)"
        case .gen1Pair: return "Joy-Con (L/R)"
        }
    }

    /// 有没有键盘以外的输入（玩家区块与「分配玩家」照这个显示）：Switch 2 手柄、蓝牙手柄、HID 兜底手柄、一代 Joy-Con。
    ///   新的输入来源加在这里——例如以后的 Mobile（同一 Wi-Fi 的手机手柄），或分得出设备的多组键盘（现在系统把所有键盘并成一路，不算）
    private var hasInputBesidesKeyboard: Bool {
        !controller.allDevices.isEmpty || !systems.pads.isEmpty || !systems.fallback.isEmpty || !systems.gen1.isEmpty
    }

    /// 「玩家」列表 = 现在的分配（接上手柄自动排进来；PlayerAssignment.reconcile），最多 8 位
    private var playerRows: [(glyph: ControllerIcon.Glyph, name: String)] {
        controller.assignment.units.map { (unitGlyph($0), unitName($0)) }
    }

    // 照 #520 UI 稿：区块由上到下 Switch 2 → 蓝牙 → 玩家，每块一个小标头，细线分隔（间距一律 4 的倍数）
    var body: some View {
        let status = controller.status
        VStack(alignment: .leading, spacing: 16) {
            // 分配中只放分配块（#520 讨论：省面板高度）；Switch 2 手柄那块、蓝牙手柄那块完成 / 取消后再出来
            if !controller.assigning {
            // Switch 2 区块：只给 S2Arm 直连（Joy-Con 2 / Pro 2）用。蓝牙手柄走下面 systems.pads 那块——两条连接通道不同，标题 / 状态不可共用
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(text: "Switch 2")
                let title = controller.switch2Title(lang: lang)   // 只讲 Switch 2 手柄（#1151），不借系统手柄名
                HStack(spacing: 12) {
                    ControllerIcon(glyph: ControllerIcon.header(kind: controller.kind, players: controller.players) ?? .unknown)
                        .frame(width: 48, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.manrope(20, .bold)).lineLimit(1).truncationMode(.tail).help(title)   // 太长一行截断（同蓝牙那块），悬停看全名
                        StatusLine(color: NS2LauncherController.dotColor(status), text: NS2LauncherController.statusText(status, lang: lang, bluetoothDenied: controller.bluetoothDenied))
                    }
                }
                .accessibilityElement(children: .combine)
                .controllerID("controller.status")

                // 主按钮（连接 / 停止 / 断开 / 重新连接）在左、齿轮在右，不论状态都一样；两个开关收进齿轮选单（之后新设定也加进去，面板不再变高）
                HStack(spacing: 8) {
                    Button(NS2LauncherController.mainButton(status, lang: lang, bluetoothDenied: controller.bluetoothDenied)) { controller.mainAction() }
                        .buttonStyle(LauncherSecondaryButtonStyle(fill: true))
                        // ⚠️ 不要改回 controllerButtonStyle / controllerID（不要把这颗注册进手柄导航）。
                        //   连接 / 断开只给鼠标点：连着时它是「断开」，面板一开手柄焦点若落在这里，玩家按 A（例如想认手柄、看玩家行亮键）
                        //   就把正在用的 Joy-Con 2 自己断掉（11-16 实机踩过）；没连时手柄本来就按不到「连接」，注册了也没用。
                        //   要断开请按手柄上的 sync 钮，或用鼠标点这颗。controllerExcluded 连 AX 兜底扫描也一起排除，见 PadExclusion
                        .controllerExcluded("controller.main-action")
                    Button { setSettings(!showSettings) } label: { Image(systemName: "gearshape").font(.system(size: 15, weight: .semibold)) }
                        .controllerButtonStyle(PanelSquareButtonStyle())   // 方钮，高度同左边主按钮
                        .help(t("settings"))
                        .accessibilityLabel(t("settings"))
                        .controllerID("controller.settings")
                        .anchorPreference(key: GearAnchorKey.self, value: .bounds) { $0 }
                }
            }

            // 蓝牙区块（#520 UI 稿 system.html）：系统蓝牙手柄——图、标题（一只写系统给的名字，太长一行截断、悬停看全名；多只写数量）、状态、「打开蓝牙设置」
            //   HID 兜底手柄（#1151：GameController 认不出、游戏里按 HID 直读的「… Pro Controller」）一并列在这一块，按 Pro 样式手柄算
            //   没有任何蓝牙手柄时也显示（同 Switch 2 区块）：虚线图、「游戏手柄 / Game controller」（同 macOS 的叫法，不列品牌）、未连接，按钮照样能去系统蓝牙设置配对
            do {
                let fallback = systems.fallback
                let names = systems.pads.map(\.name) + fallback
                let families = systems.pads.map(\.family) + fallback.map { _ in SystemControllers.Family.nintendoPro }
                let title = names.isEmpty ? t("gameController")
                    : names.count == 1 ? names[0] : t("bluetoothCount").replacingOccurrences(of: "{0}", with: "\(names.count)")
                let glyph: ControllerIcon.Glyph = names.isEmpty ? .unknown
                    : ControllerIcon.system(Set(families).count == 1 ? families[0] : .other)   // 多只同一类用那一类的图，混着用通用手柄图
                let state: NS2LauncherController.Status = names.isEmpty ? .notConnected : .connected
                PanelSection {
                    SectionHeader(text: t("bluetooth"))
                    HStack(spacing: 12) {
                        ControllerIcon(glyph: glyph).frame(width: 48, height: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.manrope(20, .bold)).lineLimit(1).truncationMode(.tail)   // 蓝牙手柄名字太长照截断（缩字太小），悬停看全名
                                .help(names.isEmpty ? title : names.joined(separator: "\n"))
                            StatusLine(color: NS2LauncherController.dotColor(state), text: NS2LauncherController.statusText(state, lang: lang))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("controller.system.status")
                    Button(t("openBluetooth")) { SystemControllers.openBluetoothSettings() }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(fill: true))
                        .controllerID("controller.system.settings")
                }
            }

            }

            // 玩家（#520 UI 稿）：平时是玩家列表 +「分配玩家」；分配中换成分配块（system.html 第 5 栏）
            if controller.assigning {
                VStack(alignment: .leading, spacing: 12) {   // 只剩这一块：上面不画分隔线
                    SectionHeader(text: t("assignPlayers"))
                    HStack(spacing: 8) {
                        HowToTile(title: t("howPair"), keys: t("howPairKeys"))
                        HowToTile(title: t("howSingle"), keys: t("howSingleKeys"))
                    }
                    VStack(spacing: 8) {
                        let units = controller.assignment.units
                        // 至少 4 行（同稿），登记到第 4 位起每多一位再露一行「等待中」，最多 8 行（同原机最多 8 位）
                        ForEach(0..<min(PlayerAssignment.maxPlayers, max(4, units.count + 1)), id: \.self) { i in
                            if i < units.count { PlayerRow(number: i + 1, glyph: unitGlyph(units[i]), name: unitName(units[i]), flashing: controller.flashingPlayers.contains(i), clearLabel: t("clear")) { controller.removePlayer(at: i) } }
                            else { WaitingRow(number: i + 1, label: t("waiting")) }
                        }
                    }
                    HStack(spacing: 8) {
                        Button(t("cancel")) { controller.cancelAssign() }.controllerButtonStyle(LauncherSecondaryButtonStyle(fill: true)).controllerShortcut(.back)   // B
                            .controllerID("controller.assign.cancel")
                        Button(t("done")) { controller.finishAssign() }.controllerButtonStyle(LauncherPrimaryButtonStyle(fill: true))
                            // A 才通用（单只 Joy-Con 没有 ZR）：分配中焦点先落在「完成」，提示也显示 A；R2 / ZR 照样能按
                            .controllerShortcut(.primary, .rightTrigger).controllerPreferredFocus(true)
                            .controllerID("controller.assign.done")
                    }
                }
                .onAppear {
                    // 进分配画面焦点落在「完成」：按「分配玩家」那一下时这两颗还没注册，导航会先挑最左边的「取消」，等注册好再放一次
                    DispatchQueue.main.async { (padControls as? LauncherPadNavigation)?.focus("controller.assign.done") }
                    systems.watchAssign { controller.registerSystem(name: $0, index: $1) }
                    systems.watchGen1 { id, side, gesture in controller.registerGen1(id: id, side: side, gesture: gesture) }
                    // 键盘：分配中按任一键就登记成下一位（#520 讨论，不加提示）；这一下吞掉，不给 S2Arm 别处当快捷键 / 不响提示音
                    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in controller.registerKeyboard(); return nil }
                }
                .onDisappear {
                    // 完成 / 取消回来：焦点回到「分配玩家」那颗（不然导航会挑最上面别的按钮，例如蓝牙设置）
                    DispatchQueue.main.async { (padControls as? LauncherPadNavigation)?.focus("controller.assign") }
                    systems.watchAssign(nil)
                    systems.watchGen1(nil)
                    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                    keyMonitor = nil
                }
            } else {
                let rows = playerRows
                if hasInputBesidesKeyboard || !rows.isEmpty {
                PanelSection {
                    if !rows.isEmpty {
                        SectionHeader(text: t("players"))
                        VStack(spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                // 点一行选中这一位（框线变奶油色）；按键时名字亮绿 + 按键小框照旧。平时不给 ×，分配中才有
                                Button { selectedPlayer = index } label: {
                                    PlayerRow(number: index + 1, glyph: row.glyph, name: row.name, selected: currentPlayer == index,
                                              flashing: controller.flashingPlayers.contains(index), showKey: true, key: controller.flashingKeys[index])
                                }
                                .controllerButtonStyle(.plain)
                                .controllerID("controller.player.\(index)")
                                .controllerRingRadius(LauncherTheme.Metrics.controlRadius)   // 玩家行圆角同主题控件
                                // 面板一开手柄焦点先落在 P1，不落在主按钮：连着时主按钮是「断开」，按 A 认手柄会把手柄断掉
                                .controllerPreferredFocus(index == 0)
                                .accessibilityLabel("P\(index + 1) \(row.name)")
                                .accessibilityAddTraits(currentPlayer == index ? .isSelected : [])
                            }
                        }
                        .accessibilityIdentifier("controller.players")
                    }
                    if let pad = controller.assignment.pad(forPlayer: currentPlayer, in: systems.pads),
                       ControllerFaceFamily(pad.family) != .nintendo {
                        ControllerFaceMappingEditor(store: controller.faceMaps, family: ControllerFaceFamily(pad.family), simplifiedChinese: zh)
                            .id(pad.id)
                    }
                    // 「分配玩家」跟着玩家区块：有键盘以外的输入（或列表已有人）就显示，不要再改回「两只以上手柄才显示」。
                    //   键盘只能在分配画面按任一键加入成 P1–P8（登记后跨次保留）；以前两只以上才显示时，
                    //   只接一只手柄就进不了分配画面、键盘加不进来，键盘 + 一只手柄时列表有 P1 + P2 也没有按钮，换不了顺序、也 × 不掉。
                    //   只有键盘时不显示：键盘本来就并进 P1，没有可分配的
                    Button(t("assignPlayers")) { controller.startAssign() }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(fill: true))
                        .controllerID("controller.assign")
                }
                }
            }
        }
        .padding(20)
        // 手柄 B：面板自己接住，不落到系统「取消」/ Esc（没人接时 macOS 会「叮」一声）。
        //   分配中 = 取消分配（同「取消」钮）；齿轮选单开着只关选单；其他时候关面板。一直挂着（用 if 切换会让整个面板换身份、状态重设）
        .controllerBackAction("controller.panel.back") {
            if controller.assigning { controller.cancelAssign() } else if showSettings { setSettings(false) } else { onClose() }
        }
        .onAppear { controller.panelDidOpen(); startPressWatch() }   // 已被拒 / 这次没选就关了授权框：面板直接显示「允许蓝牙」
        .onDisappear { stopPressWatch(); controller.panelDidClose() }
        .frame(width: 380)   // 比稿（340）宽一些：标题不会整行撑满
        // 齿轮选单画在面板里（齿轮下方浮层），不另开弹窗：弹窗里再开弹窗时 macOS 会重建外层弹窗、沿用旧高度，
        //   面板内容被上下裁掉（11-16 实机：先没连、面板里连上后再开选单改开关就跑版）。同一窗口，手柄 / B 也简单
        .overlayPreferenceValue(GearAnchorKey.self) { anchor in
            GeometryReader { g in
                if showSettings, let anchor {
                    let gear = g[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { setSettings(false) }
                            .accessibilityHidden(true)
                        Switch2SettingsMenu(controller: controller, lang: lang) { setSettings(false) }
                            .offset(x: max(10, min(gear.maxX - Switch2SettingsMenu.width, g.size.width - Switch2SettingsMenu.width - 10)), y: gear.maxY + 8)
                    }
                }
            }
        }
        .background(.regularMaterial)
        .launcherDropdownHost()
        .preferredColorScheme(.dark)
    }
}

private struct GearAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

extension Switch2ProConnectionPopover {
    /// 开 / 关齿轮选单：开时手柄焦点进第一个开关，关时回齿轮
    func setSettings(_ open: Bool) {
        showSettings = open
        let navigation = padControls as? LauncherPadNavigation
        DispatchQueue.main.async { navigation?.focus(open ? "controller.settings.autoConnect" : "controller.settings") }
    }
}

// 认手柄：面板开着时，哪只手柄按了键，玩家列表那一行的名字亮一下（Switch 2 经连接程序、蓝牙手柄 / 一代 Joy-Con / 键盘在本进程读）
extension Switch2ProConnectionPopover {
    func startPressWatch() {
        controller.setPressWatch(true)
        // 分配中所有手柄都能操作界面：Switch 2 / 一代 Joy-Con 的按键转成导航动作（系统手柄本来就走 GameController 导航）
        let navigation = padControls as? LauncherPadNavigation
        controller.onAssignNavigate = { navigation?.handle($0) }
        systems.watchPress { name, index, key in controller.flashPlayer(key: key) { $0 == .system(name: name, index: index) } }
        systems.watchGen1Press { id, key in
            if controller.assigning, let key, let navigation {
                var side = -1, sideways = true
                for unit in controller.assignment.units {
                    if case let .gen1(unitID, s) = unit, unitID == id { side = s }
                    if case let .gen1Pair(l, r) = unit, l == id || r == id { side = l == id ? 0 : 1; sideways = false }
                }
                if side < 0 { side = systems.gen1.first { $0.id == id }?.side ?? 1 }
                if let action = NS2LauncherController.padAction(gen1Key: key, side: side, sideways: sideways) { navigation.handle(action) }
            }
            controller.flashPlayer(key: key) { unit in
                switch unit {
                case let .gen1(unitID, _): return unitID == id
                case let .gen1Pair(left, right): return left == id || right == id
                default: return false
                }
            }
        }
        if pressKeyMonitor == nil {
            // 分配中键盘另有用处（按任一键登记成一位，那边的监听会吞掉这一下），这里只在平时亮一下、不吞键
            pressKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if !controller.assigning { controller.flashPlayer(key: Self.keyLabel(event)) { $0 == .keyboard } }
                return event
            }
        }
    }
    /// 键盘按键 → 显示的字（最多两个字）
    static func keyLabel(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 49: return "␣"
        case 51, 117: return "⌫"
        case 53: return "⎋"
        default:
            let text = (event.charactersIgnoringModifiers ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return text.isEmpty ? nil : String(text.prefix(2))
        }
    }
    func stopPressWatch() {
        controller.setPressWatch(false)
        controller.onAssignNavigate = nil
        systems.watchPress(nil)
        systems.watchGen1Press(nil)
        if let pressKeyMonitor { NSEvent.removeMonitor(pressKeyMonitor) }
        pressKeyMonitor = nil
    }
}

// 稿里的 .sec：上面一条细线、内容间距 12
private struct PanelSection<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            content
        }
    }
}

// 区块小标头（Switch 2 / 蓝牙 / 玩家）：13 semibold、次要色
private struct SectionHeader: View {
    let text: String
    var body: some View { Text(text).font(.manrope(13, .semibold)).foregroundStyle(.secondary) }
}

// 状态行：8×8 圆点 + 15 semibold 次要色
private struct StatusLine: View {
    let color: NSColor
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: color)).frame(width: 8, height: 8)
            Text(text).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
        }
    }
}

// 齿轮选单：Switch 2 连接的持久化开关（行为与存法不变）；之后新设定加在这里
struct Switch2SettingsMenu: View {
    @ObservedObject var controller: NS2LauncherController
    let lang: String
    let close: () -> Void
    static let width: CGFloat = 360   // 稿上 300；Manrope 15 下英文开关字会折行，放宽到 360
    private func t(_ key: String) -> String { NS2LauncherController.text("s2arm.controller." + key, lang) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 开着时 S2Arm 一启动就连（不必打开面板）：起连接程序扫 10 秒，之后只挂着等记住的手柄回来，不持续扫描
            ToggleRow(label: t("autoConnect"),
                      isOn: Binding(get: { controller.autoConnectOnOpen }, set: { controller.setAutoConnectOnOpen($0) }))
                .controllerID("controller.settings.autoConnect")
            ToggleRow(label: t("disconnectOnClose"),
                      isOn: Binding(get: { controller.disconnectAfterGame }, set: { controller.setDisconnectAfterGame($0) }))
                .controllerID("controller.settings.disconnectOnClose")
        }
        .padding(16)
        .frame(width: Self.width)
        .launcherDropdownSurface()   // 同主题下拉：材质底、边框、阴影
        .onExitCommand { close() }   // 键盘 Esc：只关齿轮选单（手柄 B 由面板的 PanelBack 处理）
    }
}

// 稿里的 .row：左边一句、右边开关（没有副标题）
private struct ToggleRow: View {
    let label: String
    let isOn: Binding<Bool>
    var body: some View {
        HStack(spacing: 16) {
            Text(label).font(.manrope(15, .semibold))
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(label)
        }
    }
}

// 齿轮方钮：与左边主按钮（LauncherSecondaryButtonStyle）同高、同底色 / 边框 / 圆角，宽 = 高
private struct PanelSquareButtonStyle: ButtonStyle, PadRingShaped {
    var padRingRadius: CGFloat { LauncherTheme.Metrics.controlRadius }
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous)
        return configuration.label
            .frame(width: LauncherControl.height, height: LauncherControl.height)
            .background(configuration.isPressed ? LauncherTheme.Colors.pressed : hovered ? LauncherTheme.Colors.hover : LauncherTheme.Colors.control, in: shape)
            .overlay(shape.strokeBorder(LauncherTheme.Colors.border))
            .foregroundStyle(enabled ? Color.white.opacity(0.92) : .gray)
            .contentShape(shape)
            .onHover { hovered = $0 }
    }
}

// 稿里的 .howto：深底小格，上面一行粗体、下面按键说明
private struct HowToTile: View {
    let title: String
    let keys: String
    var body: some View {
        VStack(spacing: 2) {   // 两行字间距 2（使用者 11-15 指定保留，不套 4 倍数）
            Text(title).font(.manrope(13, .semibold)).foregroundStyle(.primary)
            Text(keys).font(.manrope(12)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(8)
        // 主题的半透明控件底 + 边框（同按钮），不用不透明深灰：面板的材质与背景色透得出来
        .background(LauncherTheme.Colors.control, in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous).strokeBorder(LauncherTheme.Colors.border))
    }
}

// 稿里的 .prow.empty：还没人登记的那一位——虚线框、玩家灯、「等待中」
private struct WaitingRow: View {
    let number: Int
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            Text("P\(number)").font(.manrope(12, .bold)).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(playerLights(number)[i] ? Color(red: 0x7b / 255, green: 0xe0 / 255, blue: 0x1e / 255) : Color(red: 0x5a / 255, green: 0x57 / 255, blue: 0x53 / 255))
                        .frame(width: 8, height: 8)
                }
            }
            Text(label).font(.manrope(13, .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous).strokeBorder(LauncherTheme.Colors.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// 玩家灯（同原机）：P1–P4 亮 1–4 格，P5–P8 是 ●○○● / ●○●○ / ●○●● / ○●●○
func playerLights(_ number: Int) -> [Bool] {
    switch number {
    case 1: return [true, false, false, false]
    case 2: return [true, true, false, false]
    case 3: return [true, true, true, false]
    case 4: return [true, true, true, true]
    case 5: return [true, false, false, true]
    case 6: return [true, false, true, false]
    case 7: return [true, false, true, true]
    case 8: return [false, true, true, false]
    default: return [false, false, false, false]
    }
}

// 「玩家」列表的一行，照 #520 UI 稿 .prow：P 号、四格玩家灯（亮到第 P 格）、40×28 的手柄图、名称
private struct PlayerRow: View {
    let number: Int
    let glyph: ControllerIcon.Glyph
    let name: String
    var selected = false   // 平时列表里点选的那一位：框线奶油色
    var flashing = false   // 这只手柄刚按了键：名字亮一下（玩家灯同色，比边框明显）
    var showKey = false    // 平时的玩家列表：最右边留一个按键小框（分配中不放）
    var key: String?       // 亮着时按的是哪个键
    var clearLabel = ""
    var onClear: (() -> Void)?

    private static let ledOn = Color(red: 0x7b / 255, green: 0xe0 / 255, blue: 0x1e / 255)
    private static let ledOff = Color(red: 0x5a / 255, green: 0x57 / 255, blue: 0x53 / 255)

    var body: some View {
        HStack(spacing: 8) {
            Text("P\(number)").font(.manrope(12, .bold)).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(playerLights(number)[i] ? Self.ledOn : Self.ledOff).frame(width: 8, height: 8)
                }
            }
            ControllerIcon(glyph: glyph).frame(width: 40, height: 28)
            Text(name).font(.manrope(13, .semibold)).lineLimit(1).truncationMode(.tail).help(name)   // 列表里的名称太长照截断（悬停看全名）
                .foregroundStyle(flashing ? Self.ledOn : Color.primary)
                .animation(.easeOut(duration: flashing ? 0.05 : 0.35), value: flashing)
            Spacer(minLength: 8)
            // 按键小框：有边线的 chip，宽度跟字走（至少两个字宽）；亮着才显示（按的哪个键），平时透明但位置保留，名字截断在它前面
            if showKey {
                Group {
                    // 「sf:」开头 = 长宽一致的图示（方向、PlayStation ✕ ○ □ △），其余照字写
                    if let key, key.hasPrefix("sf:") { Image(systemName: String(key.dropFirst(3))).font(.system(size: 10, weight: .bold)).frame(width: 12, height: 12) }
                    else { Text(key ?? "").font(.manrope(12, .bold)).lineLimit(1).fixedSize() }
                }
                    .foregroundStyle(Self.ledOn)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 32, minHeight: 20)
                    .overlay(Capsule().stroke(Self.ledOn, lineWidth: 1))
                    .opacity(flashing && key != nil ? 1 : 0)
                    .animation(.easeOut(duration: flashing ? 0.05 : 0.35), value: flashing)
                    .accessibilityHidden(true)
            }
            // 最右边一个小 ×：清空这一位；名字截断在它前面，不会盖住
            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .controllerButtonStyle(.plain)
                .help(clearLabel)
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        // 主题的半透明控件底 + 边框（同按钮）；选中那一位框线奶油色
        .background(LauncherTheme.Colors.control, in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous).strokeBorder(selected ? LauncherPalette.cream.opacity(0.7) : LauncherTheme.Colors.border))
        .accessibilityElement(children: .contain)
    }
}

