// S2Arm（不是上游文件）：一款游戏的启动设置（「开始游戏」旁的齿轮、「更多」菜单里同一入口；11-09 维护者）。
//   设置项只从共享定义表 launchers/shared/game_settings.v1.json 读（iOS 游戏内菜单同一份），这里不另写文案和缺省；
//   读写走作业层 community / communitySave（存这款游戏文件夹的 launch.json），改完下次开始游戏生效，不用重新准备。
//   可用与否按这款的能力清单，不可用时显示原因。「手柄与按键」打开现有的按键设置页。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

/// 一项的状态（作业层 community 结果的 mac 字段）：值是 Bool（开关）或 String（选项）。
struct LaunchOption {
    let available: Bool
    let value: Any?
    let reason: String

    init(_ raw: Any?) {
        let row = raw as? [String: Any] ?? [:]
        available = row["available"] as? Bool ?? false
        value = row["value"]
        reason = row["reason"] as? String ?? ""
    }
}

/// 画面补丁一项（community 结果的 graphics；玩家包一般没有）。
struct LaunchPatch: Identifiable {
    let id: String
    let label: String
    let enabled: Bool
}

extension S2ArmLauncherModel {
    /// 读（change 为空）或改这款的启动设置；change 的键是定义表 id，值 Bool / String，NSNull = 回缺省。
    func launchSettings(_ gameID: String, change: [String: Any]? = nil, patches: [String: Bool]? = nil) async throws -> ([String: LaunchOption], [LaunchPatch]) {
        var extra: [String: Any] = [:]
        if let change { extra["settings"] = change }
        if let patches { extra["graphics"] = patches }
        let result = try await saveJob(extra.isEmpty ? "community" : "communitySave", gameID: gameID, extra: extra)
        let mac = (result["mac"] as? [String: Any] ?? [:]).mapValues(LaunchOption.init)
        let gfx = (result["graphics"] as? [[String: Any]] ?? []).compactMap { g -> LaunchPatch? in
            guard let id = g["id"] as? String else { return nil }
            return LaunchPatch(id: id, label: g["label"] as? String ?? id, enabled: g["enabled"] as? Bool ?? false)
        }
        return (mac, gfx)
    }
}

struct LaunchSettingsSheet: View {
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: S2ArmLauncherModel
    let gameID: String
    /// 「手柄与按键」：关掉本页、打开按键设置页
    var openInput: () -> Void = {}
    @State private var items: [GameSettingItem] = []
    @State private var options: [String: LaunchOption] = [:]
    @State private var patches: [LaunchPatch] = []
    @State private var failure: String?
    @State private var saving = false
    @State private var loaded = false

    private var lang: String { loc.lang == .zh ? "zh-Hans" : "en" }
    private func t(_ id: String) -> String { BackendText.launcherText(id, language: lang) }
    private var gameName: String { model.games.first { $0.id == gameID }?.name ?? gameID }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("display.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                Text(gameName).font(.manrope(14)).foregroundStyle(.secondary).lineLimit(1)
                Text(t("display.hint")).font(.manrope(12.5)).foregroundStyle(.secondary).padding(.top, 6)
            }
            if let failure {
                Label { Text(loc.backend(failure)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                    .font(.manrope(12.5)).foregroundStyle(LauncherPalette.danger)
            }
            if !loaded && failure == nil {
                ProgressView().controlSize(.small)
            } else if loaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(["display", "controls", "other"], id: \.self) { group in
                            let rows = items.filter { $0.group == group && visible($0) }
                            if !rows.isEmpty {
                                CardGroup(t("display.group." + group)) {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                                        if i > 0 { CardDivider() }
                                        row(item)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(t("display.done")) { dismiss() }.buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(30)
        .frame(width: 600, height: 640)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .task { if !loaded { await load(nil) } }
    }

    /// 补丁一栏只在这款列得出补丁时出现；开关 / 选项要作业层给了状态才画
    private func visible(_ item: GameSettingItem) -> Bool {
        switch item.type {
        case "patches": return !patches.isEmpty
        case "page": return true
        default: return options[item.id] != nil
        }
    }

    @ViewBuilder private func row(_ item: GameSettingItem) -> some View {
        let title = item.text(lang)
        switch item.type {
        case "page":
            CardRow(title, detail: item.detail(lang)) {
                Button(t("display.open")) { dismiss(); openInput() }.buttonStyle(LauncherSecondaryButtonStyle())
                    .accessibilityIdentifier("launch." + item.id)
            }
        case "patches":
            CardRow(title, detail: item.detail(lang)) { EmptyView() }
            ForEach(patches) { p in
                CardRow("  " + p.label) {
                    Toggle("", isOn: Binding(get: { p.enabled }, set: { on in Task { await load(nil, patches: [p.id: on]) } }))
                        .toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(p.label).disabled(saving || model.busy)
                }
            }
        case "choice":
            let option = options[item.id]
            CardRow(title, detail: option?.available == false ? loc.backend(option?.reason ?? "") : item.detail(lang)) {
                Picker("", selection: Binding(get: { option?.value as? String ?? "" }, set: { v in Task { await load([item.id: v]) } })) {
                    ForEach(item.options, id: \.value) { o in Text(o.label[lang] ?? o.value).tag(o.value) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 150).accessibilityLabel(title)
                .accessibilityIdentifier("launch." + item.id)
                .disabled(option?.available != true || saving || model.busy)
            }
        default:
            let option = options[item.id]
            CardRow(title, detail: option?.available == false ? loc.backend(option?.reason ?? "") : item.detail(lang)) {
                Toggle("", isOn: Binding(get: { option?.value as? Bool ?? false }, set: { on in Task { await load([item.id: on]) } }))
                    .toggleStyle(LauncherSwitchStyle()).labelsHidden().accessibilityLabel(title)
                    .accessibilityIdentifier("launch." + item.id)
                    .disabled(option?.available != true || saving || model.busy)
            }
        }
    }

    private func load(_ change: [String: Any]?, patches change2: [String: Bool]? = nil) async {
        saving = true; defer { saving = false }
        do {
            if items.isEmpty { items = try GameSettingsSpec.macItems() }
            (options, patches) = try await model.launchSettings(gameID, change: change, patches: change2)
            failure = nil; loaded = true
        } catch {
            failure = (error as? JobClientError)?.message ?? error.localizedDescription
        }
    }
}
