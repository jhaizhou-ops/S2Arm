// Derived from NX2Apple frontend/Sources/NX2Apple/LauncherView.swift (908e4e84, MIT; see ../../UPSTREAM.md).
// S2Arm changes: one page, the Library (the Builds and Settings pages, engine sync banner, artwork editor, Manage menu, console mode
// are not taken); the state is S2ArmLauncherModel (adapter services) instead of LauncherStores; while a game runs
// the library gives way to JobSessionView (the launch job's events and Stop), and Back returns to the library. Second cut: the top bar
// adds Add games (open panel, or drop files on the window → import job) and the environment check (EnvironmentView); the options
// sheet is joined by the install-to-iPhone sheet (InstallView); any job (prepare, install, import) runs in JobSessionView. Export
// (11-07): a game's Export opens ExportView in place of the library (platforms, options, start), and an export runs in
// ExportSessionView (platform queue, steps, time left, per-platform results); the free-up-space sheet (FreeSpaceView) and
// change library (JobSessionView, setup job) sit beside them.
// Switch 2 Pro: the top bar adds the controller button and popover (Switch2ProConnectionPopover), and the library starts the
//   controller connection on appear when the user enabled it (NS2LauncherController).
// Console Home: selected banners fill the window behind the titlebar; toolbar actions use compact, labeled icons.
// Headings: brand and version share a baseline, reserving the native titlebar actions' measured width.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct LauncherView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @ObservedObject var home: HomeLibraryState
    @ObservedObject var navigation: LauncherPadNavigation
    @EnvironmentObject var loc: Localizer
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Namespace var consoleSpace   // iPhone 总控台：首位卡手机轮廓升到页顶的共享元素过渡（LauncherView+PhoneConsole）
    @StateObject var padFocus = PadFocus()
    @StateObject var covers = CoverCache()
    @State var installFor: String?
    @State var spaceFor: String?
    @State var moreFor: String?
    @State var saveFor: String?
    /// 拖到卡片上的存档：随存档窗口一起打开、先检查（SaveManageSheet.source）
    @State var saveDrop: URL?
    /// 拖动经过的那张卡片（描边提示）
    @State var dropCard: String?
    @State var displayFor: String?
    @State var inputFor: String?
    @State var deleteFor: GameSummary?
    /// 「找不到游戏文件」的那款（点了卡片）：重新指定文件夹 / 从游戏库移除
    @State var missingFor: GameSummary?
    @State private var showController = false
    @State private var dropTargeted = false
    @State private var showMessages = false
    @State private var updateErrorDismissed = false   // 更新失败 toast 按 × 关掉；状态一变（重试 / 再失败）就重置
    @State private var titlebarActionsWidth: CGFloat = 0
    @State var showHomeSearch = false
    @State private var returnToInstallFromEnv: String?
    @State private var returnToDisplayFromInput: String?
    @State private var returnToEnvFromSpace = false
    let brand: String

    init(model: S2ArmLauncherModel, brand: String) {
        self.model = model; self.brand = brand
        self.home = model.home; self.navigation = model.gamepad
    }

    /// What the host's own messages use: the launch job takes zh-Hans or en.
    var uiLanguage: String { loc.lang.sharedCode }

    var body: some View {
        presentedContent
            .environment(\.padControls, navigation)
            .controllerButtonStyle(DefaultButtonStyle())
            .toggleStyle(PadToggleStyle(SwitchToggleStyle()))
    }

    private var presentedContent: some View {
        VStack(spacing: 0) {
            topBar
            if !showingHome { Divider().opacity(0.3) }
            noticeBar
            phoneUpdateBar
            libraryNoticeBar
            if model.batchShown {
                BatchExportView(model: model, covers: covers, install: { installFor = $0 }, freeSpace: { spaceFor = $0 }, uiLanguage: uiLanguage)
            } else if let result = model.viewingResult, let run = result.export {
                ExportSessionView(model: model, covers: covers, session: result, run: run, install: { installFor = $0 }, freeSpace: { spaceFor = $0 }, uiLanguage: uiLanguage)
            } else if let session = model.session, let run = session.export, !model.sessionHidden {
                ExportSessionView(model: model, covers: covers, session: session, run: run, install: { installFor = $0 }, freeSpace: { spaceFor = $0 }, uiLanguage: uiLanguage)
            } else if let session = model.session, session.export == nil, !model.sessionHidden, !model.isInline(session) {
                if session.kind == .play { PlaySessionView(model: model, covers: covers, session: session, uiLanguage: uiLanguage) }
                else { JobSessionView(model: model, session: session) }
            } else if let phone = model.phoneSession, phone.kind == .installUpdate, !model.phoneHidden {   // 更新 iPhone 上的 S2Arm（手机槽）：主槽没占着整页时整页显示
                JobSessionView(model: model, session: phone)
            } else if let id = model.exportFor, let game = model.games.first(where: { $0.id == id }) {
                ExportView(model: model, covers: covers, game: game) { installFor = game.id }
            } else {
                libraryPage
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 18).strokeBorder(LauncherPalette.cream, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                .padding(16).allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                        Self.fileURLs(providers) { urls in
                            // 拖进来的是 prod.keys 就当密钥放，别当游戏报错
                            if urls.count == 1, urls[0].pathExtension.lowercased() == "keys" { model.importKeys(urls[0]) } else { model.importGames(urls, partialResults: true) }
                        }
                        return true
                    }
            }
        }
        .overlay(alignment: .bottom) { updateErrorToast }
        .animation(.easeOut(duration: 0.2), value: model.updateState)
        .onChange(of: model.updateState) { _ in updateErrorDismissed = false }
        .padScope("main", padFocus)
        .environmentObject(padFocus)
        .launcherDropdownHost()
        .ignoresSafeArea(.container, edges: .top)
        .background {
            if showingHome {
                HomeBackdrop(game: homeSelected, covers: covers).ignoresSafeArea()
            } else if let backdropGame {
                ZStack {
                    HomeBackdrop(game: backdropGame, covers: covers)
                        .blur(radius: 36, opaque: true)
                    LinearGradient(
                        colors: [
                            LauncherPalette.background.opacity(0.60),
                            LauncherPalette.background.opacity(0.76)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
            } else {
                LauncherWindowMaterial().ignoresSafeArea()
            }
        }
        .background(LauncherWindowChrome())
        .background(LauncherPadHost(navigation: navigation, update: configurePadNavigation))
        .onReceive(model.controller.$deviceCount.dropFirst()) { _ in
            DispatchQueue.main.async { navigation.source.refreshPresentation() }
        }
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .font(LauncherTheme.TypeStyle.detail)
        .labelStyle(LauncherLabelStyle())
        .frame(minWidth: 800, minHeight: 450)
        .onAppear { model.startup() }
        .sheet(isPresented: $model.sgradeUpgradeOpen) { SGradeUpgradeView(model: model).environmentObject(loc) }   // S 级优化升级（v0.4.0）
        .sheet(item: Binding(get: { installFor.map(OptionsTarget.init) }, set: { installFor = $0?.id })) { target in
            InstallView(model: model, gameID: target.id, onOpenSettings: { returnToInstallFromEnv = target.id }).environmentObject(loc)
        }
        .onChange(of: model.spaceRequest) { id in if let id { spaceFor = id; model.spaceRequest = nil } }   // 设置页「磁盘空间」
        .onChange(of: model.displayRequest) { id in if let id { displayFor = id; model.displayRequest = nil } }   // 控制口打开启动设置
        .sheet(item: Binding(get: { spaceFor.map(OptionsTarget.init) }, set: {
            spaceFor = $0?.id
            if $0 == nil, returnToEnvFromSpace {
                returnToEnvFromSpace = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.showEnvironment = true }
            }
        })) { target in
            FreeSpaceView(model: model, gameID: target.id).environmentObject(loc)
        }
        .sheet(item: Binding(get: { displayFor.map(OptionsTarget.init) }, set: { displayFor = $0?.id })) { target in
            LaunchSettingsSheet(model: model, gameID: target.id, openInput: {
                returnToDisplayFromInput = target.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { inputFor = target.id }
            }).environmentObject(loc)
        }
        .sheet(item: Binding(get: { saveFor.map(OptionsTarget.init) }, set: { saveFor = $0?.id; if $0 == nil { saveDrop = nil } })) { target in
            SaveManageSheet(model: model, gameID: target.id, source: saveDrop).environmentObject(loc)
        }
        .sheet(item: Binding(get: { inputFor.map(OptionsTarget.init) }, set: {
            inputFor = $0?.id
            if $0 == nil, let back = returnToDisplayFromInput {
                returnToDisplayFromInput = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { displayFor = back }
            }
        })) { target in
            InputSettingsSheet(model: model, gameID: target.id).environmentObject(loc)
        }
        .sheet(item: Binding(get: { model.diagUploadFor.map(OptionsTarget.init) }, set: { model.diagUploadFor = $0?.id })) { target in   // 上传给开发者（游戏库菜单 / 控制口）
            UploadDiagnosticsSheet(model: model, gameID: target.id.isEmpty ? nil : target.id, operations: nil, fallback: "") { model.diagUploadFor = nil }.environmentObject(loc)
        }
        .background(DownstreamPromptHost(model: model))   // 下游深度方案确认页（DownstreamConfirmSheet.swift）
        .background(CrashPromptHost(model: model))       // 上次开着金手指 / 补丁时异常退出：已当场关掉，开局时通知关了哪几条
        .alert(txt("game.delete.title").replacingOccurrences(of: "{0}", with: deleteFor?.name ?? ""), isPresented: Binding(get: { deleteFor != nil }, set: { if !$0 { deleteFor = nil } })) {
            Button(txt("game.cancel"), role: .cancel) { deleteFor = nil }
            Button(txt("game.delete.confirm"), role: .destructive) { if let g = deleteFor { model.deleteGame(g) }; deleteFor = nil }
        } message: { Text(txt("game.delete.body") + (deleteFor?.onPhone == true ? "\n\n" + txt("game.delete.onPhone") : "")) }
        .alert(txt("library.missing.title").replacingOccurrences(of: "{0}", with: missingFor?.name ?? ""), isPresented: Binding(get: { missingFor != nil }, set: { if !$0 { missingFor = nil } })) {
            Button(txt("library.missing.relink")) { if let g = missingFor { relinkGame(g) }; missingFor = nil }
            Button(txt("library.missing.forget"), role: .destructive) { if let g = missingFor { model.forgetGame(g) }; missingFor = nil }
            Button(txt("game.cancel"), role: .cancel) { missingFor = nil }
        } message: { Text(txt("library.missing.body")) }
        // 换游戏库撞上认得出的风险（云盘同步目录 / 有别的文件的文件夹，S2ArmLauncherModel.libraryConfirmCodes）：讲清后果，玩家选「仍然继续」带上对应参数重来（v0.3.1）
        .alert(BackendText.errorTitle(model.libraryConfirm?.code ?? "library_in_cloud", language: uiLanguage) ?? txt("install.drop_title"), isPresented: Binding(get: { model.libraryConfirm != nil }, set: { if !$0 { model.libraryConfirm = nil } })) {
            Button(txt("install.drop_confirm")) { if let c = model.libraryConfirm { model.libraryConfirm = nil; model.changeLibrary(to: c.url, move: c.move, accept: c.accept) } }
            Button(txt("phone.drop.cancel"), role: .cancel) { model.libraryConfirm = nil }
        } message: { Text(loc.backend(model.libraryConfirm?.message ?? "")) }
        .sheet(isPresented: $model.showAddGames) { ImportSheet(model: model, kind: .games).environmentObject(loc) }
        // 打开时最多一个更新弹窗（有新版 / 这版更新了什么），只给最新一期；关掉（含 Esc）= 这一版不再弹
        .sheet(isPresented: Binding(get: { model.updatePopup != nil && !model.showAddGames && !model.showKeys && !model.showEnvironment }, set: { if !$0, model.updatePopup != nil { model.closeUpdatePopup() } })) {
            if model.updatePopup?["kind"] as? String == "feature" {   // 大版本首次打开的新功能大窗（docs/site/feature.json，updater.py feature_spotlight）
                FeatureSpotlightView(model: model, language: uiLanguage)
            } else {
                UpdatePopupView(model: model, language: uiLanguage)
            }
        }
        .alert(txt(model.updateGate ?? "update.gate.busy"), isPresented: Binding(get: { model.updateGate != nil && model.updatePopup == nil }, set: { if !$0 { model.updateGate = nil } })) {
            Button(txt("update.after.ok"), role: .cancel) { model.updateGate = nil }
        } message: { Text(txt((model.updateGate ?? "update.gate.busy") + ".body")) }
        .sheet(isPresented: Binding(get: { model.showKeys && !model.showEnvironment }, set: { model.showKeys = $0 })) {
            ImportSheet(model: model, kind: .keys).environmentObject(loc)
        }
        .sheet(isPresented: $model.showEnvironment) {
            EnvironmentView(model: model, onOpenSpace: { returnToEnvFromSpace = true }).environmentObject(loc)
        }
        .onChange(of: model.showEnvironment) { shown in
            if !shown, !returnToEnvFromSpace, let back = returnToInstallFromEnv {
                returnToInstallFromEnv = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { installFor = back }
            }
        }
    }

    /// 删除游戏 / 清除缓存的进行中与结果（S2ArmLauncherModel.libraryNotice）：点下就出现，成功几秒后自己收起，失败留着等玩家关
    /// 新版启动器首次启动后的 iPhone 版 S2Arm 横幅（S2ArmLauncherModel+PhoneBanner.swift）：准备中 / 已准备好 / 连上自动更新 / 更新进度
    @ViewBuilder private var phoneUpdateBar: some View {
        if let line = model.phoneBannerLine {
            HStack(spacing: 10) {
                if line.percent != nil || model.phoneBanner == .preparing { ProgressView().controlSize(.small) }
                else { Image(systemName: "iphone.and.arrow.forward").foregroundStyle(LauncherPalette.cream) }
                let label = Text(txt(line.key).replacingOccurrences(of: "{0}", with: "\(line.percent ?? 0)")).font(.manrope(13, .semibold)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if line.percent == nil && model.phoneBanner != .preparing {   // 手动更新（11-16）：横幅文字点了 = 顶栏「更新 iPhone」，玩家点了才装
                    Button { model.requestPhoneUpdate(language: model.provider.client.environment.uiLanguage ?? "zh-Hans") } label: { label }
                        .controllerButtonStyle(.plain).accessibilityIdentifier("notice.phoneUpdate.open")
                } else { label }
                Spacer(minLength: 8)
                if line.percent == nil {
                    Button { model.phoneBanner = nil } label: { Image(systemName: "xmark") }.controllerButtonStyle(.plain).foregroundStyle(.secondary)
                        .help(txt("notice.close")).accessibilityLabel(txt("notice.close")).accessibilityIdentifier("notice.phoneUpdate.close")
                }
            }
            .padding(.horizontal, LauncherTheme.Metrics.libraryInset).padding(.vertical, 10)
            .background(LauncherPalette.cream.opacity(0.10))
            .accessibilityIdentifier("notice.phoneUpdate")
        }
    }

    @ViewBuilder private var libraryNoticeBar: some View {
        if let n = model.libraryNotice {
            let text = loc.t(n.key + "." + { switch n.kind { case .running: "running"; case .done: "done"; case .failed: "failed" } }())
                .replacingOccurrences(of: "{0}", with: n.name).replacingOccurrences(of: "{1}", with: loc.backend(n.detail))
            HStack(spacing: 10) {
                switch n.kind {
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LauncherPalette.danger)
                }
                Text(text).font(.manrope(13, .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if n.kind != .running {
                    Button { model.libraryNotice = nil } label: { Image(systemName: "xmark") }.controllerButtonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityIdentifier("notice.library.close")
                }
            }
            .padding(.horizontal, LauncherTheme.Metrics.libraryInset).padding(.vertical, 10)
            .background((n.kind == .failed ? LauncherPalette.danger : LauncherPalette.cream).opacity(0.10))
            .accessibilityIdentifier("notice.library")
            .task(id: n) { if n.kind == .done { try? await Task.sleep(nanoseconds: 6_000_000_000); if model.libraryNotice == n { model.libraryNotice = nil } } }
        }
    }

    static var displayVersion: String {
        let info = Bundle.main.infoDictionary
        if let shown = info?["S2ADisplayVersion"] as? String, !shown.isEmpty { return shown }
        return (info?["CFBundleShortVersionString"] as? String).map { "v" + $0 + "-dev" } ?? "dev"   // swift run 等不经 build_app 的开发构建
    }

    private var wordmark: some View {
        Image(nsImage: BrandArt.wordmark).resizable().interpolation(.high).frame(width: 108, height: 28)
    }
    // 界面作者署名；名字带作者主页链接，不加提示，当小彩蛋
    private var credit: some View {
        Text(Self.uiCredit).font(.manrope(9, .medium)).foregroundStyle(.secondary).tint(.secondary)
            .lineLimit(1).fixedSize().accessibilityIdentifier("topbar.credit")
    }
    private var version: some View {
        Text(verbatim: Self.displayVersion).font(.manrope(8.5, .medium)).monospacedDigit().foregroundStyle(.tertiary)
            .lineLimit(1).fixedSize().textSelection(.enabled).help(Self.displayVersion).accessibilityIdentifier("topbar.version")
    }
    /// 「UI by NX2Apple, SkyRiN & shenxianmq」：两位界面作者的名字各自链到主页，样式与正文一样（shenxianmq：11-17 首页 / 出包页 / 更新流程交互设计，#1498）。
    static let uiCredit: AttributedString = {
        var text = AttributedString("UI by NX2Apple, ")
        var skyrin = AttributedString("SkyRiN")
        skyrin.link = URL(string: "https://x.com/skyrin1008")
        text.append(skyrin)
        text.append(AttributedString(" & "))
        var shen = AttributedString("shenxianmq")
        shen.link = URL(string: "https://github.com/shenxianmq")
        text.append(shen)
        return text
    }()

    /// 非首页（出包页、批量出包、游玩/作业进度与结果页）复用当前游戏的高斯模糊背景，保持与首页一致的磨砂质感。
    private var backdropGame: GameSummary? {
        let id: String?
        if model.batchShown { id = model.batchSeed }
        else if let result = model.viewingResult, result.export != nil { id = result.gameID }
        else if let session = model.session, !model.sessionHidden, !model.isInline(session) { id = session.gameID }
        else if let idExport = model.exportFor { id = idExport }
        else { id = nil }
        return id.flatMap { gid in model.games.first { $0.id == gid } } ?? homeSelected
    }

    private var topBar: some View { topBarRow.onChange(of: model.showInstallFor) { id in if let id { installFor = id; model.showInstallFor = nil } } }   // 控制口 /show install（单独一层：挂在 body 长链上编译器类型检查超时）

    private var topBarRow: some View {
        HStack(spacing: 12) {
            // 点品牌字标回欢迎页（社区贡献者补丁 #2）
            HStack(alignment: .center, spacing: LauncherTheme.Space.medium) {
                Button { installFor = nil; model.goToLibrary(); model.welcomeHome = true } label: {
                    // 字标 957×247，左边 247×247 是 S 图标：右侧按钮太宽（法语窄窗口）时只留图标，不被挤到红绿灯上
                    ViewThatFits(in: .horizontal) {
                        wordmark
                        wordmark.frame(width: 28, alignment: .leading).clipped()
                    }
                }
                .controllerButtonStyle(.plain).controllerID("top.brand").accessibilityLabel(brand).layoutPriority(1)
                // 窄窗口先收版本号、再收署名，不压右侧按钮
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LauncherTheme.Space.medium) { credit; version }
                    credit
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 90).padding(.trailing, max(24, titlebarActionsWidth + LauncherTheme.Space.medium))
        .frame(height: 52)   // = a unified toolbar's title bar: the system centres the traffic lights in it, so they share this bar's midline
        .background(TitlebarDoubleClick())
        .background(UnifiedTitlebar(actions: topActions, actionsWidth: $titlebarActionsWidth))
    }

    /// 顶栏右侧的按钮放进标题栏本身：工具栏盖在窗口内容上，内容里的按钮收不到真实点击（11-08 维护者）。
    private var topActions: some View {
        HStack(spacing: 8) {
                if model.loading { ProgressView().controlSize(.small) }
                exportPill
                backgroundTaskPill
                batchPill
                PhoneUpdateButton(model: model, language: uiLanguage)
                phonePill
                updateButton
                // 玩家、手柄跟右边的圆钮放在一起（文字胶囊在左），右侧一排都是圆钮
                PlayerToolbarButton(loc: loc)   // 本地玩家（#623）：这次用谁的身份玩，点开切换 / 添加；标题栏另起视图树、环境对象传不进去，显式给
                ControllerToolbarButton(controller: model.controller, show: $showController,
                                        lang: loc.lang.code)
                messagesButton
                Button { installFor = nil; model.goToLibrary() } label: {
                    Label(loc.t("s2arm.nav.library"), systemImage: "square.grid.2x2")
                        .foregroundStyle(showingHome && !model.showsWelcome ? LauncherPalette.cream : .white)
                }
                .controllerButtonStyle(ConsoleIconButtonStyle()).help(loc.t("s2arm.nav.library"))
                .controllerID("top.library")
                Button { model.showAddGames = true } label: {
                    Label(loc.t("s2arm.action.import"), systemImage: "plus")
                }
                .controllerButtonStyle(ConsoleIconButtonStyle()).disabled(model.busy)
                .help(loc.t("s2arm.action.import")).controllerID("top.import")
                // 设置按钮角标只在「缺东西、要处理」时挂红点（#1426：原先就绪时常驻绿点，玩家当成未读，点进去找不到新内容）；
                //   就绪 / 检查中都不挂，「环境已就绪」在设置页里看。悬停与无障碍在缺东西时说清是什么事
                Button { model.showEnvironment = true } label: {
                    Image(systemName: "gearshape").overlay(alignment: .topTrailing) {
                        if environmentNeedsAction {
                            Circle().fill(LauncherPalette.danger).frame(width: 5, height: 5).offset(x: 5, y: -3)
                        }
                    }
                }
                .controllerButtonStyle(ConsoleIconButtonStyle())
                .help(environmentNeedsAction ? txt("nav.settings") + "：" + loc.t("s2arm.env.missing") : txt("nav.settings"))
                .accessibilityLabel(txt("nav.settings"))
                .accessibilityValue(environmentNeedsAction ? loc.t("s2arm.env.missing") : "")
                .controllerID("top.settings")
                // 故障报修（11-13）：任何页面同一位置（顶栏最右，Windows 同位），点开就是全局「上传给开发者」弹窗（不针对某款，
                //   作业层自动附最近一次失败的错误摘要）；报错页的指引 ReportHint 指的就是它
                Button { model.diagUploadFor = "" } label: {
                    Label(BackendText.launcherText("report.button", language: uiLanguage), systemImage: "exclamationmark.bubble")
                }
                .controllerButtonStyle(ConsoleIconButtonStyle()).help(txt("report.button"))
                .controllerID("top.report").accessibilityIdentifier("top.report")
        }
        .padding(.trailing, LauncherTheme.Space.section)
        .fixedSize()   // 放在标题栏里没有宽度约束，不固定的话按钮文字会被压成省略号
        .labelStyle(.titleAndIcon)   // Popovers keep their text; icon styles are local to each toolbar button.
        .tint(LauncherPalette.cream)
        .environment(\.colorScheme, .dark)
        .environment(\.padControls, navigation)
        .controllerButtonStyle(DefaultButtonStyle())
        .toggleStyle(PadToggleStyle(SwitchToggleStyle()))
    }

    /// A unified toolbar makes the (transparent) title bar as tall as the top bar, and macOS then centres the close / minimise / zoom
    /// buttons vertically in it. The right-hand actions are its one item, so real clicks reach them.
    private struct UnifiedTitlebar<Actions: View>: NSViewRepresentable {
        let actions: Actions
        @Binding var actionsWidth: CGFloat

        final class ActionsHost: NSHostingView<Actions> {
            var didLayout: (() -> Void)?
            override func layout() { super.layout(); didLayout?() }
        }

        final class Coordinator: NSObject, NSToolbarDelegate {
            let host: ActionsHost
            @Binding private var width: CGFloat
            init(_ actions: Actions, width: Binding<CGFloat>) {
                host = ActionsHost(rootView: actions); _width = width
                super.init()
                host.didLayout = { [weak self] in self?.reportWidth() }
            }
            func update(_ actions: Actions, width: Binding<CGFloat>) {
                _width = width; host.rootView = actions
                reportWidth()
            }
            private func reportWidth() {
                guard host.bounds.width > 0, abs(host.bounds.width - width) > 0.5 else { return }
                // This hosting view lives outside the page's SwiftUI preference tree.
                // Publish its actual AppKit width after layout, using the latest value.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.host.window != nil else { return }
                    let value = self.host.bounds.width
                    if value > 0, abs(value - self.width) > 0.5 { self.width = value }
                }
            }
            func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
            func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
            func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
        }

        final class Host: NSView {
            var coordinator: Coordinator?
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window, window.toolbar == nil else { return }
                let toolbar = NSToolbar(identifier: "s2arm.titlebar")
                toolbar.delegate = coordinator
                toolbar.displayMode = .iconOnly
                toolbar.allowsUserCustomization = false
                window.toolbar = toolbar
                window.toolbarStyle = .unified
                window.titlebarSeparatorStyle = .none
                // 工具栏只负责标题栏高度。按钮直接放进标题栏：放进工具栏项时 macOS 26 会在整组下面再垫一层玻璃胶囊，和按钮自己的胶囊叠在一起
                guard let close = window.standardWindowButton(.closeButton), let bar = close.superview, let host = coordinator?.host else { return }
                host.translatesAutoresizingMaskIntoConstraints = false
                bar.addSubview(host)
                NSLayoutConstraint.activate([host.trailingAnchor.constraint(equalTo: bar.trailingAnchor), host.centerYAnchor.constraint(equalTo: close.centerYAnchor)])
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator(actions, width: $actionsWidth) }
        func makeNSView(context: Context) -> NSView { let h = Host(); h.coordinator = context.coordinator; return h }
        func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.update(actions, width: $actionsWidth) }
    }

    private struct OptionsTarget: Identifiable { let id: String }

    /// 环境缺东西、要玩家处理（顶栏设置按钮挂红点）。readyMac（Mac 上能玩、只差打 iPhone 包的项）照旧算就绪、不挂：只玩 Mac 的玩家不该一直看到提醒，缺的项在设置页单列
    private var environmentNeedsAction: Bool { model.environmentState == .missing }

    /// 顶部公告条（v0.2.3）：醒目的琥珀色底、整条宽，压在内容上方但不盖住任何按钮；× 关掉后同一条不再出现。文字取自 notice.json，代码里不写公告内容
    @ViewBuilder private var noticeBar: some View {
        if let notice = model.notice, let text = (notice["text"] as? [String: String])?[uiLanguage] {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LauncherPalette.building)
                (Text(txt("notice.label") + "  ").font(.manrope(13, .bold)) + Text(text).font(.manrope(13)))
                    .foregroundStyle(LauncherPalette.cream).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 8)
                if let link = (notice["url"] as? String).flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(txt("notice.details")).font(.manrope(12.5, .semibold)).underline() }
                        .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
                Button { model.dismissNotice() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream.opacity(0.8)).help(txt("notice.close")).accessibilityLabel(txt("notice.close"))
            }
            .padding(.horizontal, LauncherTheme.Metrics.libraryInset).padding(.vertical, 10)
            .background(LauncherPalette.building.opacity(0.16))
            .overlay(alignment: .bottom) { Rectangle().fill(LauncherPalette.building.opacity(0.45)).frame(height: 1) }
        }
    }

    /// 有新版：顶栏一颗「有新版 vX」（点开更新弹窗，玩家点「现在更新」才下）；下载时一行小字。都在顶栏，不打断玩家。
    @ViewBuilder private var updateButton: some View {
        switch model.updateState {
        case .working(let id, let percent):
            Button { if model.availableUpdate != nil { model.showUpdatePopup() } } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(txt(id).replacingOccurrences(of: "{0}", with: "\(percent ?? 0)")).font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .controllerButtonStyle(.plain)
            .help(txt(id).replacingOccurrences(of: "{0}", with: "\(percent ?? 0)"))
        case .ready:
            Button { model.showUpdatePopup() } label: {
                Label(txt("update.top.available").replacingOccurrences(of: "{0}", with: model.availableUpdate?["version"] as? String ?? ""), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(LauncherPalette.cream)
            }
            .controllerButtonStyle(ConsoleIconButtonStyle())
            .help(txt("update.top.available").replacingOccurrences(of: "{0}", with: model.availableUpdate?["version"] as? String ?? ""))
            .controllerID("top.update")
        case .idle where model.availableUpdate != nil:
            // 草图：「以后再说」之后顶栏留「有新版 vX」，点开回到更新弹窗①（「现在更新并重启」在弹窗里；有局在跑时那里先拦下说明）
            Button { model.showUpdatePopup() } label: {
                Label(txt("update.top.available").replacingOccurrences(of: "{0}", with: model.availableUpdate?["version"] as? String ?? ""), systemImage: "arrow.down.circle")
            }
            .controllerButtonStyle(ConsoleIconButtonStyle())
            .help(txt("update.top.available").replacingOccurrences(of: "{0}", with: model.availableUpdate?["version"] as? String ?? ""))
            .controllerID("top.update")
        case .failed(let code):
            // 顶栏只留「重试」；失败原因（人话 + 错误码 + 打开下载页）放到底部的错误 toast，× 可关，不再挤在顶栏里跑版
            Button { model.downloadUpdate() } label: { Text(txt("update.retry")).font(.manrope(12.5, .semibold)).lineLimit(1) }
                .controllerButtonStyle(LauncherSecondaryButtonStyle())
                .help(txt("update.error." + code))
        case .idle: EmptyView()
        }
    }

    /// 更新失败的错误 toast：贴在窗口底部，× 关掉后这次失败不再显示；再失败（重试后）会重新出现
    @ViewBuilder private var updateErrorToast: some View {
        if case .failed(let code) = model.updateState, !updateErrorDismissed {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(LauncherPalette.danger)
                VStack(alignment: .leading, spacing: 3) {
                    Text(txt("update.error." + code)).font(.manrope(13, .semibold)).foregroundStyle(LauncherPalette.cream)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(txt("update.code").replacingOccurrences(of: "{0}", with: code)).font(.manrope(11.5)).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                Spacer(minLength: 8)
                Button { NSWorkspace.shared.open(S2ArmLauncherModel.downloadPage) } label: { Text(txt("update.download_page")).font(.manrope(12.5, .semibold)).lineLimit(1) }
                    .controllerButtonStyle(LauncherSecondaryButtonStyle())
                Button { withAnimation(.easeOut(duration: 0.2)) { updateErrorDismissed = true } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream.opacity(0.8))
                .help(txt("notice.close")).accessibilityLabel(txt("notice.close"))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .background(LauncherPalette.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherPalette.danger.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(.horizontal, 24).padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    func txt(_ id: String) -> String { BackendText.launcherText(id, language: uiLanguage) }

    /// 「消息」：公告和更新说明都在这里（旧的只在这里、不弹）；未读只算最新那条公告
    private var messagesButton: some View {
        Button { showMessages = true; model.openMessages() } label: {
            Image(systemName: "bell").overlay(alignment: .topTrailing) {
                if model.unreadMessages > 0 {
                    Circle().fill(LauncherPalette.danger).frame(width: 6, height: 6).offset(x: 4, y: -3)
                }
            }
        }
        .controllerButtonStyle(ConsoleIconButtonStyle()).help(txt("messages.button"))
        .accessibilityLabel(txt("messages.button")).accessibilityValue("\(model.unreadMessages)").controllerID("top.messages")
        .popover(isPresented: $showMessages, arrowEdge: .bottom) { MessagesPanel(model: model, language: uiLanguage) }
    }

    /// 非出包任务收起后，也保留一条可用手柄返回进度页的入口。
    @ViewBuilder private var backgroundTaskPill: some View {
        if let session = model.session, session.export == nil, !session.isPhoneJob, !model.isInline(session), model.sessionHidden {
            Button { model.sessionHidden = false } label: {
                Label(loc.t("home.currentTask"), systemImage: session.kind == .play ? "gamecontroller" : "list.bullet.rectangle")
                    .font(.manrope(12.5, .semibold))
            }.controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("top.currentTask")
                .accessibilityLabel(loc.t("home.currentTask") + " · " + session.name)
        }
        // 收起的、或被主槽整页（出包进度等）压着的「更新 iPhone 上的 S2Arm」：回到它的进度页
        if let phone = model.phoneSession, phone.kind == .installUpdate,
           model.phoneHidden || (model.session.map { !model.sessionHidden && ($0.export != nil || !model.isInline($0)) } ?? false) {
            Button { model.phoneHidden = false; model.sessionHidden = true } label: {
                Label(phone.name, systemImage: "iphone").font(.manrope(12.5, .semibold)).lineLimit(1)
            }.controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("top.phoneTask")
        }
    }

    /// 批量出包（v0.2.4）：清单页没开着时，这批正在出 / 上次还有没出完的 → 顶部胶囊回到清单页
    @ViewBuilder private var batchPill: some View {
        if !model.batchShown, model.batchRunning || model.batchUnfinished > 0 {
            Button { model.batchShown = true } label: {
                HStack(spacing: 7) {
                    if model.batchRunning { ProgressView().controlSize(.mini) } else { Image(systemName: "list.bullet.rectangle") }
                    Text(model.batchRunning ? BackendText.launcherText("batch.title", language: uiLanguage)
                         : BackendText.launcherText("batch.unfinished", language: uiLanguage).replacingOccurrences(of: "{0}", with: "\(model.batchUnfinished)"))
                        .font(.manrope(12.5, .semibold)).lineLimit(1)
                }
            }
            .controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("top.batch")
        }
    }

    /// 收起运行页、或还有排队时：顶部这颗胶囊回到出包页。
    @ViewBuilder private var exportPill: some View {
        if let session = model.session, session.export != nil, model.sessionHidden {
            Button { model.sessionHidden = false } label: {
                HStack(spacing: 7) {
                    if model.mainBusy { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(LauncherPalette.ready) }
                    Text(txt(model.mainBusy ? "export.pill.running" : "export.pill.done").replacingOccurrences(of: "{0}", with: session.name)).font(.manrope(12.5, .semibold)).lineLimit(1)
                    if !model.exportQueue.isEmpty {
                        Text(txt("export.pill.queue").replacingOccurrences(of: "{0}", with: "\(model.exportQueue.count)")).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .controllerButtonStyle(LauncherSecondaryButtonStyle())
        }
    }

    /// 装机弹窗关着时：手机作业在跑 → 「正在装到 iPhone · 查看进度」，点了回到同一个作业（弹窗显示 model.session，不新起安装）；
    /// 跑完还没回去看 → 「已装好 / 没装完 · 查看结果」（#308，Mac 与 Windows 同一套入口）。
    @ViewBuilder private var phonePill: some View {
        if installFor == nil {
            if let s = model.phoneSession, S2ArmLauncherModel.phoneKinds.contains(s.kind), let id = s.gameID {
                Button { installFor = id } label: {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(txt(model.selfSigning && s.kind == .install ? "install.pill.exporting" : "install.pill.running").replacingOccurrences(of: "{0}", with: s.name).replacingOccurrences(of: "{1}", with: model.installTargetLabel)).font(.manrope(12.5, .semibold)).lineLimit(1)
                        if let f = s.progress.fraction { Text("\(Int(f * 100))%").font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                .controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.pill")
            } else if let r = model.phoneResult {
                Button { installFor = r.gameID } label: {
                    HStack(spacing: 7) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(r.ok ? LauncherPalette.ready : LauncherPalette.danger)
                        Text(txt(!r.ok ? (model.selfSigning ? "install.pill.exportFailed" : "install.pill.failed") : (model.phoneOutcome?.exportFolder ?? "").isEmpty ? "install.pill.done" : "install.pill.exported").replacingOccurrences(of: "{0}", with: r.name)
                             .replacingOccurrences(of: "{1}", with: r.ok && !model.installedTo.isEmpty ? model.installedTo : model.installTargetLabel)).font(.manrope(12.5, .semibold)).lineLimit(1)
                    }
                }
                .controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("install.pill")
            }
        }
    }

    /// The file URLs of a drop, delivered together on the main queue.
    static func fileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

private struct ControllerToolbarButton: View {
    @ObservedObject var controller: NS2LauncherController
    @StateObject private var systems = SystemControllers()   // 系统手柄（PS5 / Xbox / 一代 Joy-Con…），面板「玩家」列表一起列（#520 F）
    @Binding var show: Bool
    let lang: String   // 界面语言代码（Lang.code）
    @Environment(\.padControls) private var padControls

    private var toolbarStatus: String {
        NS2LauncherController.statusText(controller.hasSystemController ? .connected : controller.status, lang: lang, bluetoothDenied: controller.bluetoothDenied)
    }
    /// 开面板：还没问过蓝牙权限就先弹系统授权框（不开面板，免得授权框抢焦点把面板关掉），选完再开、按钮已是对应状态
    private func toggle() {
        if show { show = false; return }
        if controller.shouldAskBluetoothFirst { controller.askBluetoothPermission { show = true } } else { show = true }
    }
    var body: some View {
        Button { toggle() } label: {
            Image(systemName: "gamecontroller").overlay(alignment: .topTrailing) {
                Circle().fill(Color(nsColor: controller.buttonColor)).frame(width: 5, height: 5).offset(x: 5, y: -3)
            }
        }
        .controllerButtonStyle(ConsoleIconButtonStyle())
        .help(controller.title(lang: lang) + "：" + toolbarStatus)   // #901：顶栏提示写实际连着的手柄名（两条通道合并看）
        .accessibilityLabel(controller.title(lang: lang) + "：" + toolbarStatus)
        .controllerID("top.controller")
        // 面板用 AppKit 的 NSPopover 自己开关，不用 SwiftUI .popover：实机上 .popover 会在背后重新呈现、套回打开时记下的高度，
        //   先没连、面板里连上（多出玩家区块）后再开齿轮选单 / 改开关，面板内容上下被裁（11-16，真窗口单测重现不出来）。
        //   高度照内容自动撑（NSHostingController.sizingOptions = .preferredContentSize），不写死
        .background(AppKitPopover(isPresented: $show) {
            Switch2ProConnectionPopover(controller: controller, systems: systems, lang: lang, onClose: { show = false })
                .environment(\.padControls, padControls)
        })
        // 蓝牙手柄接上 / 断开：分配跟着整理（新连上的自动排进玩家位，#520 E）
        .onReceive(systems.$pads) { pads in controller.updateSystem(SystemControllers.keys(for: pads)) }
        .onReceive(systems.$gen1) { controller.updateGen1($0) }   // 一代 Joy-Con 按设备（D2）   // 用送来的新值（@Published 在改之前就送，读属性还是旧的）
        // 游戏打开了系统的手柄设置画面：面板自己弹出来（已进分配玩家）
        .onChange(of: controller.panelRequested) { wanted in if wanted { controller.panelRequested = false; if !show { toggle() } } }
    }
}

/// 用 AppKit NSPopover 呈现 SwiftUI 内容：开关由 isPresented 决定，内容大小跟着 SwiftUI 的理想大小走（preferredContentSize），
///   不会被 SwiftUI 在背后重新呈现、套回旧高度。点外面关（transient），关了把 isPresented 设回 false
private struct AppKitPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: () -> Content

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: AppKitPopover
        var popover: NSPopover?
        var host: NSHostingController<Content>?
        init(_ parent: AppKitPopover) { self.parent = parent }
        func popoverDidClose(_ notification: Notification) {
            popover = nil; host = nil
            if parent.isPresented { parent.isPresented = false }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if isPresented {
            if let host = c.host { host.rootView = content(); return }
            guard view.window != nil else { return }
            let host = NSHostingController(rootView: content())
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.contentViewController = host
            popover.behavior = .transient
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.delegate = c
            c.host = host; c.popover = popover
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil, c.popover === popover else { return }
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)   // 按钮下方
            }
        } else if let popover = c.popover {
            popover.performClose(nil)
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.popover?.close() }
}
