// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import GameController
import LauncherPadBridge
import SwiftUI
import XCTest
import NXCore
import NXModel
@testable import NXLauncher
import S2ArmAppleAdapter
@testable import NX2AppleUI

/// Real SwiftUI pages with original, asset-free job responses; never reads the player's library.
@MainActor final class SettingsLayoutTests: XCTestCase {
    func testControllerSettingsHideSharedFaceBindingsForEveryPlayer() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            for player in 0..<4 {
                let (host, window) = try await render(AnyView(InputSettingsSheet(model: fixture.model, gameID: "fixture")), fixture: fixture, language: language)
                let navigation = fixture.navigation
                navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
                window.makeKeyAndOrderFront(nil)
                defer { navigation.detach(); window.close() }
                try await settle(window, navigation, fixture.model.gamepad)
                let players = navigation.controlTargets(in: window).filter { abs($0.frame.height - 30) < 0.5 }
                    .sorted { $0.frame.minX < $1.frame.minX }
                XCTAssertEqual(players.count, 4)
                let playerRect = window.convertFromScreen(players[player].frame)
                try click(CGPoint(x: playerRect.midX, y: playerRect.midY), in: window)
                // 等选中态真画出来再判：固定等 180 ms 在整套负载下偶发取到旧色。每 50 ms 截一次取色，选中即停，最多等 3 秒
                let point = host.convert(CGPoint(x: playerRect.minX + 5, y: playerRect.midY), from: nil)
                var red: CGFloat = 0
                let deadline = Date().addingTimeInterval(3)
                repeat {
                    try await Task.sleep(for: .milliseconds(50))
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                    let sampleY = host.isFlipped ? point.y : host.bounds.maxY - point.y
                    red = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scale), y: Int(sampleY * scale))?.usingColorSpace(.deviceRGB)).redComponent
                } while red <= 0.8 && Date() < deadline
                XCTAssertGreaterThan(red, 0.8, "必须实际选中玩家\(player + 1)，不能重复验证玩家 1")
                for target in ["A", "B", "Y", "X", "L"] {
                    navigation.focus("input.map." + target)
                    let key = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "input.map." + target })
                    let rect = window.convertFromScreen(key.frame)
                    try click(CGPoint(x: rect.midX, y: rect.midY), in: window)
                    if let scroll = scrollViews(in: host).first(where: { $0.hasVerticalScroller }) {
                        scroll.contentView.scroll(to: .zero)
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    try await Task.sleep(for: .milliseconds(70))
                    let targets = navigation.controlTargets(in: window)
                    XCTAssertEqual(targets.contains { $0.id == "input.gamepad" }, target == "L",
                        "\(language.code)/玩家\(player + 1)/\(target)：四键由共享弹窗管理，其他实体键继续可编辑")
                    XCTAssertTrue(targets.contains { $0.id == "input.keyboard.record" }, "四键的独立键盘绑定仍须可用")
                    if player == 3 && target == "X" { try snapshot(host, "input-shared-faces-" + language.code) }
                }
                navigation.focus("input.gamepad"); navigation.handle(.confirm)
                try await waitUntil { navigation.controlTargets(in: window).contains { $0.id == "dropdown.leftShoulder" } }
                let ids = navigation.controlTargets(in: window).map(\.id)
                for code in InputConfig.padCodes.prefix(4) {
                    XCTAssertFalse(ids.contains("dropdown." + code), "所有玩家都不能用逐游戏配置覆盖实体四键")
                }
                XCTAssertTrue(ids.contains("dropdown.leftShoulder"), "其余实体键仍须可绑定")
            }
        }
    }

    func testStorageModeAlignsWithTheHeadingAndContentInBothModes() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(FreeSpaceView(model: fixture.model, gameID: "fixture")), fixture: fixture, language: language)
            let navigation = fixture.navigation
            navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
            defer { navigation.detach(); window.close() }
            for overview in [false, true] {
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(navigation.shortcutTargets(in: window)[.secondary] != nil, overview, "只有存储总览显示刷新操作，确认切换实际生效")
                let modes = navigation.controlTargets(in: window).filter { abs($0.frame.height - 30) < 0.5 }
                    .sorted { $0.frame.minX < $1.frame.minX }
                XCTAssertEqual(modes.count, 2)
                let first = try XCTUnwrap(modes.first), last = try XCTUnwrap(modes.last)
                let bounds = window.convertToScreen(host.bounds)
                print("storage-mode \(language.code)/\(overview): left=\(first.frame.minX - bounds.minX - 3)")
                XCTAssertEqual(first.frame.minX - bounds.minX, 35, accuracy: 1,
                    "分段控件与页头、内容共用 32 pt 左边距；按钮本身另有 3 pt 内边距")
                XCTAssertEqual(last.frame.maxX - first.frame.minX + 6, 300, accuracy: 1, "仍保持 300 pt 的紧凑宽度")
                try snapshot(host, "storage-mode-\(language.code)-\(overview ? "overview" : "game")")
                if !overview { navigation.focus(last.id); navigation.handle(.confirm) }
            }
        }
    }

    func testPlayResultAlignsWithPageInsetsAndTheSharedPrimaryAction() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogCover = "original-play-cover"
        let artwork = NSImage(size: CGSize(width: 100, height: 100), flipped: false) { rect in
            NSColor(deviceRed: 0.8, green: 0.1, blue: 0.9, alpha: 1).setFill()
            rect.fill(); return true
        }
        let covers = CoverCache { _, _ in CoverCache.Loaded(version: "original", image: artwork) }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for language in [Lang.zh, .en] {
            for (width, height): (CGFloat, CGFloat) in [(800, 450), (1120, 630), (1440, 810)] {
                let session = JobSession(kind: .play, gameID: game.id, name: game.name,
                    phase: .finished(.completed), stage: "游戏运行中")
                fixture.model.session = session
                let page = AnyView(PlaySessionView(model: fixture.model, covers: covers, session: session,
                    uiLanguage: language == .zh ? "zh-Hans" : "en")
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text)
                    .preferredColorScheme(.dark).frame(width: width, height: height))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                for connected in [false, true] {
                    fixture.navigation.presentation.connected = connected
                    try await Task.sleep(for: .milliseconds(80))
                    let back = try XCTUnwrap(fixture.navigation.controlTargets(in: window).first)
                    let bounds = window.convertToScreen(host.bounds)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / width
                    // The original magenta cover isolates the information column from text and material shadows.
                    let first = try XCTUnwrap((0..<bitmap.pixelsWide).first { x in
                        guard let color = bitmap.colorAt(x: x, y: Int(80 * scale))?.usingColorSpace(.deviceRGB) else { return false }
                        return color.redComponent - color.greenComponent > 0.3 && color.blueComponent - color.greenComponent > 0.3
                    })
                    let left = CGFloat(first) / scale, buttonFrame = back.frame
                    print("play-result \(language.code)/\(width)/\(connected): left=\(left), right=\(bounds.maxX - buttonFrame.maxX), bottom=\(buttonFrame.minY - bounds.minY), height=\(buttonFrame.height)")
                    XCTAssertEqual(left, 48, accuracy: 1, "游戏信息与游戏库共用 48 pt 左边距")
                    XCTAssertEqual(back.id, "play.back")
                    XCTAssertEqual(bounds.maxX - buttonFrame.maxX, 48, accuracy: 1, "回库按钮应放在右下角，与其他页面右边缘对齐")
                    XCTAssertEqual(buttonFrame.minY - bounds.minY, 16, accuracy: 1)
                    XCTAssertEqual(buttonFrame.height, 48, accuracy: 1, "使用共用的突出主按钮尺寸")
                    XCTAssertTrue(bounds.contains(buttonFrame))
                    let shortcuts = fixture.navigation.shortcutTargets(in: window)
                    XCTAssertEqual(shortcuts[.rightTrigger], ["play.back"])
                    XCTAssertEqual(shortcuts[.back], ["play.back"])
                    try snapshot(host, "play-result-\(language.code)-\(Int(width))-\(connected ? "connected" : "disconnected")")
                }
            }
        }
    }

    func testPlayFooterActionsKeepTheirBehaviorInRunningStoppingAndFailedStates() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for phase in [JobSession.Phase.running, .stopping, .finished(.failed)] {
            let session = JobSession(kind: .play, gameID: game.id, name: game.name, phase: phase, stage: "游戏运行中")
            fixture.model.session = session
            let page = AnyView(PlaySessionView(model: fixture.model, covers: CoverCache(), session: session, uiLanguage: "en")
                .background(LauncherWindowMaterial()).frame(width: 800, height: 450))
            let (host, window) = try await render(page, fixture: fixture, language: .en)
            let navigation = fixture.navigation
            navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
            defer { navigation.detach(); window.close() }
            navigation.presentation.connected = true
            try await Task.sleep(for: .milliseconds(80))
            let bounds = window.convertToScreen(host.bounds)
            let actionID = phase == .finished(.failed) ? "play.back" : "play.stop"
            let button = navigation.controlTargets(in: window).first { $0.id == actionID }
            if phase == .stopping {
                XCTAssertNil(button, "正在停止时不能重复发送停止动作")
            } else {
                let frame = try XCTUnwrap(button).frame
                XCTAssertTrue(bounds.contains(frame), "小窗口中失败说明滚动，底栏操作始终可见")
                XCTAssertEqual(bounds.maxX - frame.maxX, 48, accuracy: 1)
                XCTAssertEqual(frame.minY - bounds.minY, 16, accuracy: 1)
                XCTAssertEqual(frame.height, 48, accuracy: 1)
            }
            if phase == .finished(.failed) {
                for action in [LauncherPadAction.confirm, .submit, .back] {
                    fixture.model.session = session
                    navigation.focus("play.back"); navigation.handle(action)
                    XCTAssertNil(fixture.model.session, "A、R2 与 B 均应执行原有回库操作")
                }
            } else {
                navigation.handle(.submit)
                XCTAssertEqual(fixture.model.session?.phase, .stopping)
            }
            XCTAssertFalse(fixture.runner.requests.contains { $0["operation"] as? String == "launch" }, "底栏操作不能意外重启游戏")
            try snapshot(host, "play-footer-\(actionID)-\(phase == .stopping ? "stopping" : "active")")
        }
    }

    func testControllerSettingsScrollKeepsFocusOnVisibleControls() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(EnvironmentView(model: fixture.model)), fixture: fixture, language: language)
            let navigation = fixture.navigation
            navigation.source.controllers = { [] }
            navigation.attach(window)
            defer { navigation.detach(); window.close() }
            let snapshot = GCController.withExtendedGamepad()
            let pad = try XCTUnwrap(snapshot.extendedGamepad)
            navigation.source.stop()
            navigation.source.controllers = { [snapshot] }
            navigation.source.isActive = { true }
            var time: TimeInterval = 0
            func press(_ down: Bool) {
                time += 0.1
                pad.dpad.setValueForXAxis(0, yAxis: down ? -1 : 1)
                navigation.source.tick(now: time)
                pad.dpad.setValueForXAxis(0, yAxis: 0)
                navigation.source.tick(now: time + 0.01)
            }
            navigation.source.tick(now: 0)
            navigation.focus("settings.language")
            let scroll = try XCTUnwrap(scrollViews(in: host).first { $0.hasVerticalScroller })
            for down in [true, false] {
                for _ in 0..<22 {
                    press(down)
                    try await Task.sleep(for: .milliseconds(25))
                    let targets = navigation.controlTargets(in: window)
                    let focused = try XCTUnwrap(targets.first { $0.id == navigation.focusedID })
                    let view = try XCTUnwrap(focused.element as? NSView)
                    if view.enclosingScrollView != nil {
                        let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(focused.unclippedFrame ?? focused.frame),
                            "\(language.code)：方向导航必须先将整个控件滚入可见区域，\(focused.id)")
                    }
                }
            }
            navigation.focus("settings.tab.iphone"); navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(80))
            navigation.focus("export.sign.mode")
            for step in 0..<14 {
                navigation.handle(.scrollDown)
                try await Task.sleep(for: .milliseconds(25))
                if let focused = navigation.controlTargets(in: window).first(where: { $0.id == navigation.focusedID }) {
                    let view = try XCTUnwrap(focused.element as? NSView)
                    let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
                    XCTAssertTrue(frame.intersects(window.convertToScreen(host.bounds)), "滚动第 \(step) 步不能留下脱离控件的焦点")
                    XCTAssertTrue(navigation.isFullyVisible(focused.id), "手动滚动后也应选中完整可见的项")
                    let ring = try XCTUnwrap(navigation.focusRingFrame(in: window))
                    XCTAssertEqual(ring.minX, focused.frame.minX, accuracy: 1)
                    XCTAssertEqual(ring.minY, focused.frame.minY, accuracy: 1)
                    XCTAssertEqual(ring.width, focused.frame.width, accuracy: 1)
                    XCTAssertEqual(ring.height, focused.frame.height, accuracy: 1)
                } else { XCTFail("滚动后焦点必须对应仍然可见的控件") }
            }
            try self.snapshot(host, "controller-settings-scrolled-" + language.code)
            if let container = host.superview { try self.snapshot(container, "controller-settings-focus-ring-" + language.code) }
        }
    }

    func testExportLocationSurvivesReopeningAndRestartingWithAnUnchangedList() async throws {
        for language in [Lang.zh, .en] {
            let fixture = try SettingsFixture()
            defer { fixture.remove() }
            let first = "/original/storage-default"
            let chosen = "/original/storage-selected"
            fixture.runner.storageResponse = ["locations": [
                ["id": "default", "path": first, "default": true, "connected": true, "freeBytes": 1000000],
                ["id": "selected", "path": chosen, "connected": true, "freeBytes": 2000000]
            ], "last": "default"]
            fixture.model.loadLocations()
            for _ in 0..<100 where fixture.model.locations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(fixture.model.locations.count, 2)
            let game = GameSummary(id: "fixture", name: "Original location fixture",
                location: GameLocation(catalog: ["state": "ok", "path": first]))
            for stage in 0..<4 {
                let model = stage < 2 ? fixture.model : S2ArmLauncherModel(client: fixture.model.provider.client)
                fixture.quiet(model)
                if stage >= 2 {
                    if stage == 3 { fixture.runner.storageResponse = ["locations": [], "last": ""] }
                    model.loadLocations()
                    try await Task.sleep(for: .milliseconds(100))
                }
                let dropdown = LauncherDropdownState()
                let padFocus = PadFocus()
                let page = AnyView(ExportView(model: model, covers: CoverCache(), game: game, install: {})
                    .environmentObject(padFocus).padScope("main", padFocus)
                    .environment(\.launcherDropdownHost, dropdown)
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text).preferredColorScheme(.dark)
                    .frame(width: 1120, height: 900))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                fixture.navigation.source.controllers = { [] }
                fixture.navigation.attach(window)
                defer { fixture.navigation.detach(); window.close() }
                fixture.navigation.focus("export.location"); fixture.navigation.handle(.confirm)
                try await Task.sleep(for: .milliseconds(80))
                let request = try XCTUnwrap(dropdown.request)
                let expected = stage == 0 ? first : chosen
                print("export-location \(language.code)/stage-\(stage): \(request.selection)")
                XCTAssertEqual(request.selection, expected, "缓存列表不变、重开页面及重启模型后都应显示已选位置")
                XCTAssertTrue(request.options.contains { $0.value == expected }, "已选但尚未登记的文件夹也应有可见名称")
                if stage == 0 { request.choose(chosen) }
                dropdown.close()
                if stage == 1 { try snapshot(host, "export-location-remembered-" + language.code) }
            }
            XCTAssertFalse(fixture.runner.requests.contains { $0["operation"] as? String == "export" }, "只选位置不能开始出包或搬游戏")
        }
    }

    func testExportActionsLiveInBottomRightAndHaveControllerShortcuts() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for platform in fixture.model.exportTargets where platform != .mac { fixture.model.toggleExport(platform) }
        if !fixture.model.exportTargets.contains(.mac) { fixture.model.toggleExport(.mac) }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1120, 1440] {
                let padFocus = PadFocus()
                let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
                    .environmentObject(padFocus).padScope("main", padFocus).frame(width: width, height: 630))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window)
                fixture.navigation.source.stop(); fixture.navigation.source.isActive = { true }
                defer { fixture.navigation.detach(); window.close() }
                let snapshot = GCController.withExtendedGamepad()
                for connected in [false, true, false] {
                    fixture.navigation.source.controllers = { connected ? [snapshot] : [] }
                    fixture.navigation.source.tick()
                    fixture.navigation.hide()
                    if let scroll = scrollViews(in: host).first, let document = scroll.documentView {
                        let clip = scroll.contentView
                        clip.scroll(to: CGPoint(x: 0, y: document.isFlipped ? 0 : max(0, document.bounds.height - clip.bounds.height)))
                        scroll.reflectScrolledClipView(clip)
                    }
                    try await Task.sleep(for: .milliseconds(70))
                    let targets = fixture.navigation.controlTargets(in: window)
                    let ids = Set(LauncherPadNavigation.elements(window).compactMap { S2ALauncherAX.identifier($0) })
                    XCTAssertFalse(ids.contains("export.back"), "出包页不再显示左上角返回")
                    let start = try XCTUnwrap(targets.first { $0.id == "export.start" })
                    let cancel = try XCTUnwrap(targets.first { $0.id == "export.cancel" })
                    let cover = try XCTUnwrap(targets.first { $0.id == "export.cover" })
                    let bounds = window.convertToScreen(host.bounds)
                    XCTAssertEqual(bounds.maxY - cover.frame.maxY, 22, accuracy: 1, "移除返回按钮后，游戏内容直接从 22 pt 顶部边距开始")
                    XCTAssertTrue(bounds.contains(cancel.frame.union(start.frame)))
                    XCTAssertGreaterThan(cancel.frame.midX, bounds.midX, "取消和开始出包都应位于右下角")
                    XCTAssertLessThanOrEqual(cancel.frame.maxX, start.frame.minX)
                    XCTAssertEqual(cancel.frame.midY, start.frame.midY, accuracy: 1)
                    XCTAssertEqual(cancel.frame.height, start.frame.height, accuracy: 1, "出包页的取消和开始按钮应同高")
                    XCTAssertEqual(cancel.frame.height, 48, accuracy: 1)
                    XCTAssertLessThan(start.frame.maxY, bounds.minY + 90)
                    let shortcuts = fixture.navigation.shortcutTargets(in: window)
                    XCTAssertEqual(shortcuts[.rightTrigger], ["export.start"])
                    XCTAssertEqual(shortcuts[.back], ["export.cancel"])
                    fixture.model.exportFor = game.id
                    fixture.navigation.focus("export.location"); fixture.navigation.handle(.back)
                    XCTAssertNil(fixture.model.exportFor, "B 与右下角取消执行相同的返回操作")
                    XCTAssertFalse(fixture.runner.requests.contains { $0["operation"] as? String == "export" }, "取消不应开始出包")
                    try self.snapshot(host, "export-actions-\(language.code)-\(Int(width))-\(connected ? "connected" : "disconnected")")
                }
            }
        }
    }

    func testSelfSignSessionMatchesTheExportPageLayout() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogCover = "original-export-cover"
        let artwork = NSImage(size: CGSize(width: 100, height: 100), flipped: false) { rect in
            NSColor(deviceRed: 0.9, green: 0.05, blue: 0.9, alpha: 1).setFill()
            rect.fill(); return true
        }
        let covers = CoverCache { _, _ in CoverCache.Loaded(version: "original", image: artwork) }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        fixture.model.selfSignAfterPack.insert(game.id)
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1120, 1440] {
                fixture.model.session = nil
                let focus = PadFocus()
                let reference = AnyView(ExportView(model: fixture.model, covers: covers, game: game, install: {})
                    .environmentObject(focus).padScope("main", focus).background(Color.black)
                    .frame(width: width, height: 630))
                let (referenceHost, referenceWindow) = try await render(reference, fixture: fixture, language: language)
                defer { referenceWindow.close() }
                let referenceBounds = referenceWindow.convertToScreen(referenceHost.bounds)
                let cover = try XCTUnwrap(fixture.navigation.controlTargets(in: referenceWindow).first { $0.id == "export.cover" })
                XCTAssertEqual(cover.frame.minX - referenceBounds.minX, 48, accuracy: 1)
                XCTAssertEqual(referenceBounds.maxY - cover.frame.maxY, 22, accuracy: 1)
                XCTAssertEqual(cover.frame.width, 236, accuracy: 1)
                XCTAssertEqual(cover.frame.height, 236 / 1.8, accuracy: 1)
                let expectedArtwork = try exportArtworkBounds(referenceHost)
                for state in [JobOutcome.State.cancelled, .completed, .failed] {
                    var run = ExportRun(platforms: [.ios])
                    if state == .completed { run.outcomes[.ios] = .init(state: .completed, appBytes: 1024, packBytes: 2048, seconds: 90) }
                    if state == .failed { run.outcomes[.ios] = .init(state: .failed, message: "Original output volume is full", code: "disk_full", suggestion: "Free space and retry") }
                    let session = JobSession(kind: .export, gameID: game.id, name: game.name, phase: .finished(state), export: run)
                    fixture.model.session = session
                    let page = AnyView(ExportSessionView(model: fixture.model, covers: covers, session: session, run: run,
                        install: { _ in }, freeSpace: { _ in }, uiLanguage: language.sharedCode)
                        .background(Color.black).foregroundStyle(LauncherTheme.Colors.text).frame(width: width, height: 630))
                    let (host, window) = try await render(page, fixture: fixture, language: language)
                    defer { window.close() }
                    // Compare painted pixels with the reference page: the rounded border
                    // excludes its outer pixels from the original magenta artwork.
                    let artworkBounds = try exportArtworkBounds(host)
                    print("self-sign-layout \(language.code)/\(width)/\(state): artwork=\(artworkBounds), reference=\(expectedArtwork)")
                    XCTAssertEqual(artworkBounds.minX, expectedArtwork.minX, accuracy: 1)
                    XCTAssertEqual(artworkBounds.minY, expectedArtwork.minY, accuracy: 1)
                    XCTAssertEqual(artworkBounds.width, expectedArtwork.width, accuracy: 1)
                    XCTAssertEqual(artworkBounds.height, expectedArtwork.height, accuracy: 1)
                    let bounds = window.convertToScreen(host.bounds)
                    let targets = fixture.navigation.controlTargets(in: window)
                    let back = try XCTUnwrap(targets.first { $0.id == (state == .completed ? "result.ios.install" : "export.session.back") })
                    print("self-sign-footer: right=\(bounds.maxX - back.frame.maxX), bottom=\(back.frame.minY - bounds.minY), height=\(back.frame.height)")
                    XCTAssertEqual(bounds.maxX - back.frame.maxX, 48, accuracy: 1)
                    XCTAssertEqual(back.frame.minY - bounds.minY, 16, accuracy: 1)
                    XCTAssertEqual(back.frame.height, 48, accuracy: 1)
                    for target in targets { XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(target.frame), "\(state)/\(width): \(target.id) \(target.frame)") }
                    if state == .completed {
                        let action = try XCTUnwrap(targets.first { $0.id == "result.ios.install" })
                        XCTAssertEqual(action.frame.height, 48, accuracy: 1, "结果页的主动作沿用出包页按钮规格")
                        XCTAssertEqual(action.id, back.id, "单平台结果的主动作应在底栏最右侧")
                        let footer = targets.filter { $0.frame.maxY < bounds.minY + 90 }
                        XCTAssertTrue(footer.contains { $0.id == "export.session.back" })
                        for target in footer { XCTAssertTrue(bounds.contains(target.frame)); XCTAssertEqual(target.frame.height, 48, accuracy: 1) }
                    }
                    try snapshot(host, "self-sign-\(language.code)-\(Int(width))-\(state)")
                }
            }
        }
    }

    func testExportIosAfterPackPickerShowsBothBranches() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let saved = fixture.model.iosAfterPack
        defer { fixture.model.iosAfterPack = saved }
        if !fixture.model.exportTargets.contains(.ios) { fixture.model.toggleExport(.ios) }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for language in [Lang.zh, .en] {
            for branch in ["install", "export"] {
                fixture.model.iosAfterPack = branch
                let padFocus = PadFocus()
                let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
                    .environmentObject(padFocus).padScope("main", padFocus).frame(width: 1120, height: 720))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window)
                defer { fixture.navigation.detach(); window.close() }
                if let scroll = scrollViews(in: host).first, let document = scroll.documentView {
                    let clip = scroll.contentView
                    clip.scroll(to: CGPoint(x: 0, y: document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0))
                    scroll.reflectScrolledClipView(clip)
                }
                try await Task.sleep(for: .milliseconds(70))
                let targets = fixture.navigation.controlTargets(in: window)
                let install = try XCTUnwrap(targets.first { $0.id == "export.after.install" })
                let export = try XCTUnwrap(targets.first { $0.id == "export.after.export" })
                XCTAssertEqual(install.frame.height, export.frame.height, accuracy: 1, "「出完之后」两张卡同高")
                XCTAssertEqual(install.frame.minY, export.frame.minY, accuracy: 1)
                try self.snapshot(host, "export-after-\(branch)-\(language.code)")
            }
        }
    }

    func testSelfSignSessionFooterKeepsBackgroundCancelAndReturnActions() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for phase in [JobSession.Phase.running, .stopping, .finished(.cancelled), .finished(.failed)] {
            let run = ExportRun(platforms: [.ios])
            let session = JobSession(kind: .export, gameID: game.id, name: game.name, phase: phase, export: run)
            fixture.model.session = session
            let page = AnyView(ExportSessionView(model: fixture.model, covers: CoverCache(), session: session, run: run,
                install: { _ in }, freeSpace: { _ in }, uiLanguage: "en").frame(width: 800, height: 450))
            let (host, window) = try await render(page, fixture: fixture, language: .en)
            let navigation = fixture.navigation
            navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
            navigation.source.isActive = { true }
            defer { navigation.detach(); window.close() }
            let bounds = window.convertToScreen(host.bounds)
            let targets = navigation.controlTargets(in: window)
            switch phase {
            case .running, .stopping:
                let background = try XCTUnwrap(targets.first { $0.id == "export.session.background" })
                XCTAssertTrue(bounds.contains(background.frame))
                XCTAssertEqual(background.frame.height, 48, accuracy: 1)
                navigation.focus(background.id); navigation.handle(.confirm)
                XCTAssertTrue(fixture.model.sessionHidden, "回库时导出仍在后台进行")
                XCTAssertEqual(fixture.model.session?.phase, phase)
                fixture.model.sessionHidden = false
                if phase == .stopping { XCTAssertFalse(targets.contains { $0.id == "export.session.cancel" }) }
                else {
                    navigation.handle(.submit)
                    XCTAssertEqual(fixture.model.session?.phase, .stopping, "右扳机仍执行原取消动作")
                }
            case .finished:
                let back = try XCTUnwrap(targets.first { $0.id == "export.session.back" })
                XCTAssertEqual(bounds.maxX - back.frame.maxX, 48, accuracy: 1)
                for action in [LauncherPadAction.confirm, .submit, .back] {
                    fixture.model.session = session
                    navigation.focus(back.id); navigation.handle(action)
                    XCTAssertNil(fixture.model.session, "结束后的回库操作必须清除会话")
                }
            }
            XCTAssertFalse(fixture.runner.requests.contains { $0["operation"] as? String == "export" }, "底栏不能意外开始另一单导出")
        }
    }

    func testExportSubmitShortcutUsesTheExistingExportAction() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for platform in fixture.model.exportTargets where platform != .mac { fixture.model.toggleExport(platform) }
        if !fixture.model.exportTargets.contains(.mac) { fixture.model.toggleExport(.mac) }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        fixture.model.exportFor = game.id
        let padFocus = PadFocus()
        let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
            .environmentObject(padFocus).padScope("main", padFocus).frame(width: 1120, height: 630))
        let (_, window) = try await render(page, fixture: fixture, language: .zh)
        let navigation = fixture.navigation
        navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
        navigation.source.isActive = { true }
        defer { navigation.detach(); window.close() }
        let snapshot = GCController.withExtendedGamepad()
        navigation.source.controllers = { [snapshot] }; navigation.source.tick(now: 0)
        navigation.focus("export.location")
        snapshot.extendedGamepad?.rightTrigger.setValue(1); navigation.source.tick(now: 0.1)
        for _ in 0..<100 where !fixture.runner.requests.contains(where: { $0["operation"] as? String == "export" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(fixture.model.exportFor, "R2 应与开始出包按钮执行同一操作")
        XCTAssertEqual(fixture.runner.requests.filter { $0["operation"] as? String == "export" }.count, 1)
        navigation.source.tick(now: 0.8)
        XCTAssertEqual(fixture.runner.requests.filter { $0["operation"] as? String == "export" }.count, 1, "长按不能重复开始出包")
    }

    /// #1272：选过方案后出包页看得到选的是哪套、能「更改」（弹同一个确认页，不顺带开出包）；没选过不出这一行（导出 iPhone 时确认页会问）
    func testExportPageShowsDownstreamChoiceWithChange() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for choice in [nil, ""] as [String?] {
            fixture.runner.catalogDownstreamChoice = choice
            fixture.model.refresh()
            for _ in 0..<200 where fixture.model.games.first?.downstream?.choice != choice || fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            let game = try XCTUnwrap(fixture.model.games.first)
            XCTAssertEqual(game.downstream?.choice, choice)
            let padFocus = PadFocus()
            let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
                .environmentObject(padFocus).padScope("main", padFocus).frame(width: 1120, height: 900))
            let (host, window) = try await render(page, fixture: fixture, language: .zh)
            let navigation = fixture.navigation
            navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
            defer { navigation.detach(); window.close() }
            let has = navigation.controlTargets(in: window).contains { $0.id == "export.downstream.change" }
            XCTAssertEqual(has, choice != nil, "选过才出「更改」（choice \(String(describing: choice))）")
            if choice != nil {
                try snapshot(host, "export-downstream-change-zh")
                let before = fixture.runner.requests.count
                navigation.focus("export.downstream.change"); navigation.handle(.confirm)
                for _ in 0..<100 where fixture.model.downstreamPromptFor == nil { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(fixture.model.downstreamPromptFor, game.id, "「更改」弹确认页")
                XCTAssertFalse(fixture.runner.requests.dropFirst(before).contains { $0["operation"] as? String == "export" }, "更改不顺带开出包")
                fixture.model.downstreamPromptFor = nil
            }
        }
    }

    /// 11-16 维护者「出包的时候没办法同时安装其他游戏到 iPhone 上，这个控制纯属多余」：手机作业走独立的手机槽。期望按规则手写：
    ///   A 在出包（主槽）时装 B → 立刻发 install、主槽那单不动；装 A → 排队不发；手机槽忙时再装 B → 排队；主槽 A 结束 → A 的装机接上
    func testInstallRunsWhileAnotherGameExportsAndQueuesRealConflicts() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogGameCount = 2
        fixture.model.refresh()
        for _ in 0..<200 where fixture.model.games.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let a = try XCTUnwrap(fixture.model.games.first { $0.id == "fixture" }), b = try XCTUnwrap(fixture.model.games.first { $0.id == "fixture-1" })
        func installs(_ id: String) -> Int { fixture.runner.requests.filter { $0["operation"] as? String == "install" && $0["gameId"] as? String == id }.count }
        var export = JobSession(kind: .export, gameID: a.id, name: a.name); export.export = ExportRun(platforms: [.ios])
        fixture.model.session = export   // A 正在出包（主槽）
        XCTAssertTrue(fixture.model.mainBusy && !fixture.model.phoneBusy)

        fixture.model.install(b, device: "dev-1")
        XCTAssertEqual(fixture.model.phoneSession?.gameID, b.id, "A 出包时装 B：手机槽立刻起")
        XCTAssertEqual(fixture.model.session?.gameID, a.id, "主槽那单不动")
        fixture.model.install(a, device: "dev-1")
        XCTAssertTrue(fixture.model.phoneQueued(a.id), "装正在出包的 A：排队")
        fixture.model.install(b, device: "dev-1")
        XCTAssertEqual(fixture.model.phoneQueue.map(\.gameID), [a.id, b.id], "手机槽忙时再装 B：排在后面")
        for _ in 0..<200 where installs(b.id) < 1 || fixture.model.phoneBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(installs(a.id), 0, "A 还在出包：A 的装机不发")
        for _ in 0..<200 where installs(b.id) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(installs(b.id), 2, "手机槽空了：排着的 B 接上（A 被主槽占着跳过它）")
        XCTAssertEqual(fixture.model.phoneQueue.map(\.gameID), [a.id])

        fixture.model.finish(.completed, message: "")   // A 出包结束
        for _ in 0..<200 where installs(a.id) < 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(installs(a.id), 1, "A 出完：A 的装机接上")
        XCTAssertTrue(fixture.model.phoneQueue.isEmpty)
    }

    func testExportNameControllerOpensKeyboardWithoutRenameAlert() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let game = GameSummary(id: "fixture", name: "Original editable game title")
        for language in [Lang.zh, .en] {
            let priorRequests = fixture.runner.requests.filter { $0["operation"] as? String == "customize" }.count
            let padFocus = PadFocus()
            let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
                .environmentObject(padFocus).padScope("main", padFocus).frame(width: 1120, height: 630)
                .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text).preferredColorScheme(.dark))
            let (host, window) = try await render(page, fixture: fixture, language: language)
            let navigation = fixture.navigation
            navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
            let loc = Localizer(language)
            navigation.text = { loc.t($0) }
            defer { navigation.detach(); window.close() }
            navigation.focus("export.name"); navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(120))
            let keyboard = try XCTUnwrap(navigation.keyboard, "手柄确认游戏标题应直接打开屏幕键盘")
            XCTAssertEqual(keyboard.value, game.name, "从现有标题开始修改")
            XCTAssertNil(window.attachedSheet, "不再打开修改名字的输入弹窗")
            XCTAssertTrue(keyboard.panel.parent === window)
            try snapshot(host, "export-name-ready-" + language.code)
            try snapshot(try XCTUnwrap(keyboard.panel.contentView), "export-name-keyboard-" + language.code)
            keyboard.value = "Cancelled title"
            navigation.handle(.back)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(fixture.runner.requests.filter { $0["operation"] as? String == "customize" }.count, priorRequests, "B 取消不能保存")
            XCTAssertEqual(navigation.focusedID, "export.name")
            navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(100))
            let second = try XCTUnwrap(navigation.keyboard)
            XCTAssertEqual(second.value, game.name)
            second.value = "Original renamed title " + language.code
            navigation.handle(.submit)
            try await Task.sleep(for: .milliseconds(150))
            let requests = fixture.runner.requests.filter { $0["operation"] as? String == "customize" }
            XCTAssertEqual(requests.count, priorRequests + 1, "确认只保存一次")
            XCTAssertEqual(requests.last?["name"] as? String, second.value)
            XCTAssertEqual(requests.last?["gameId"] as? String, game.id)
            XCTAssertNil(navigation.keyboard)
            XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == navigation.focusedID }, "保存时的短暂禁用不能留下失效焦点")
            try snapshot(host, "export-name-controller-" + language.code)
        }
    }

    func testExportCheckboxCanBeReachedAndLeftWithTheDpad() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let game = GameSummary(id: "fixture", name: "Original long game title for controller navigation")
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1120, 1440] {
                let padFocus = PadFocus()
                let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
                    .environmentObject(padFocus).padScope("main", padFocus).frame(width: width, height: 810)
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text).preferredColorScheme(.dark))
                let (_, window) = try await render(page, fixture: fixture, language: language)
                let navigation = fixture.navigation
                navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
                defer { navigation.detach(); window.close() }
                let targets = navigation.controlTargets(in: window)
                let checkbox = try XCTUnwrap(targets.first { $0.id == "export.sgrade.toggle" })
                print("export-checkbox \(language.code)/\(width): \(targets.map { "\($0.id)=\($0.frame)" }.joined(separator: ", "))")
                // 平台卡按标识认（iPhone / Apple TV / Mac 三张，Apple TV 卡在出包机配了 Apple TV 时才有），不按高度猜
                let platforms = targets.filter { $0.id.hasPrefix("export.platform.") }.sorted { $0.frame.minX < $1.frame.minX }
                let mac = try XCTUnwrap(platforms.first { $0.id == "export.platform.mac" })
                // 复选框与平台之间夹着 mod 一行（「？」格式说明，11-17）：方向键逐行走，不跳行
                let modHelp = targets.first { $0.id == "export.sgrade.mod.help" }
                navigation.focus(mac.id); navigation.handle(.up)
                if let modHelp {
                    XCTAssertEqual(navigation.focusedID, modHelp.id, "向上应先进平台上方紧邻的 mod 一行")
                    navigation.handle(.up)
                }
                XCTAssertEqual(navigation.focusedID, checkbox.id, "向上应先经过紧邻的平台上方的复选框，不能跳过整行")
                navigation.focus("export.name"); navigation.handle(.down)
                XCTAssertEqual(navigation.focusedID, checkbox.id, "标题向下也应进入复选框，不能停在同一行的封面")
                navigation.focus(checkbox.id); navigation.handle(.up)
                XCTAssertNotEqual(navigation.focusedID, checkbox.id, "向上应离开复选框回到游戏信息")
                navigation.focus(checkbox.id); navigation.handle(.down)
                if let modHelp { XCTAssertEqual(navigation.focusedID, modHelp.id, "向下先进 mod 一行"); navigation.handle(.down) }
                XCTAssertTrue(platforms.contains { $0.id == navigation.focusedID }, "向下应离开复选框进入可选平台")
                let before = fixture.model.sgradeOn(game.id)
                navigation.focus(checkbox.id); navigation.handle(.confirm)
                try await waitUntil { fixture.model.sgradeOn(game.id) != before }
                XCTAssertEqual(fixture.model.sgradeOn(game.id), !before)
                XCTAssertEqual(navigation.focusedID, checkbox.id, "切换勾选后仍保持有效焦点")
                navigation.handle(.down)
                if let modHelp { XCTAssertEqual(navigation.focusedID, modHelp.id); navigation.handle(.down) }
                XCTAssertTrue(platforms.contains { $0.id == navigation.focusedID }, "勾选状态改变后也能移出")
                XCTAssertEqual(fixture.model.sgradeOn(game.id), !before, "方向导航不能修改勾选")
            }
        }
    }

    func testExportNameMouseEditsTheHeadingAndEscapeCancels() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let game = GameSummary(id: "fixture", name: "Original long title to edit directly in the heading")
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1120, 1440] {
                fixture.model.exportFor = game.id
                let padFocus = PadFocus()
                let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
                    .environmentObject(padFocus).padScope("main", padFocus).frame(width: width, height: 630)
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text).preferredColorScheme(.dark))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                let navigation = fixture.navigation
                navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
                window.makeKeyAndOrderFront(nil)
                defer { navigation.detach(); window.close() }
                func clickTitle() throws {
                    host.layoutSubtreeIfNeeded()
                    let title = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "export.name" })
                    let point = window.convertFromScreen(CGRect(x: title.frame.minX + 20, y: title.frame.midY, width: 0, height: 0)).origin
                    try click(point, in: window)
                }
                let before = fixture.runner.requests.filter { $0["operation"] as? String == "customize" }.count
                try clickTitle()
                try await waitUntil { window.firstResponder is NSTextView }
                try await Task.sleep(for: .milliseconds(60))
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                XCTAssertEqual(editor.string, game.name, "点击标题应直接开始编辑原有名字")
                editor.selectAll(nil)
                let replacement = "Original edited heading " + language.code
                editor.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(60))
                try key(36, "\r", in: window)
                try await waitUntil {
                    !fixture.model.customizing
                        && fixture.runner.requests.filter { $0["operation"] as? String == "customize" }.count == before + 1
                        && navigation.controlTargets(in: window).contains { $0.id == "export.name" }
                        && !(window.firstResponder is NSTextView)
                }
                let saved = fixture.runner.requests.filter { $0["operation"] as? String == "customize" }
                XCTAssertEqual(saved.count, before + 1, "Return 保存与失焦回调合计只提交一次")
                XCTAssertEqual(saved.last?["name"] as? String, replacement)
                XCTAssertNil(window.attachedSheet)
                XCTAssertNil(navigation.keyboard, "鼠标编辑保持原位输入")
                try snapshot(host, "export-name-inline-\(language.code)-\(Int(width))")
                try clickTitle()
                try await waitUntil { window.firstResponder is NSTextView }
                try await Task.sleep(for: .milliseconds(60))
                let cancelEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
                cancelEditor.selectAll(nil)
                cancelEditor.insertText("Discard this heading", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(60))
                try key(53, "\u{1b}", in: window)
                try await waitUntil { !(window.firstResponder is NSTextView) }
                XCTAssertEqual(fixture.runner.requests.filter { $0["operation"] as? String == "customize" }.count, before + 1)
                XCTAssertEqual(fixture.model.exportFor, game.id, "Esc 只取消标题编辑，不能退出出包页")
                try clickTitle()
                try await waitUntil { window.firstResponder is NSTextView }
                try await Task.sleep(for: .milliseconds(60))
                XCTAssertEqual((window.firstResponder as? NSTextView)?.string, game.name, "取消后应恢复已有标题")
                try key(53, "\u{1b}", in: window)
            }
        }
    }

    private func key(_ code: UInt16, _ characters: String, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
    }

    func testHomeShouldersMoveTheFocusRingToTheSelectedTab() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let navigation = fixture.model.gamepad
        navigation.source.controllers = { [] }
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1120] {
                fixture.model.home.group = .all
                let (_, window) = try await render(AnyView(LauncherView(model: fixture.model, brand: "Original tab fixture")
                    .frame(width: width, height: 630)), fixture: fixture, language: language)
                navigation.attach(window); navigation.source.stop(); navigation.source.isActive = { true }
                defer { navigation.detach(); window.close() }
                let controller = GCController.withExtendedGamepad(), pad = try XCTUnwrap(controller.extendedGamepad)
                navigation.source.controllers = { [controller] }; navigation.source.tick(now: 0)
                navigation.focus("home.group.all")
                var time = 0.01
                for expected in [HomeGroup.ready, .recent, .favorites, .all] {
                    pad.rightShoulder.setValue(1); navigation.source.tick(now: time)
                    pad.rightShoulder.setValue(0); navigation.source.tick(now: time + 0.01)
                    time += 0.1
                    let id = "home.group." + expected.rawValue
                    try await waitUntil {
                        guard fixture.model.home.group == expected, navigation.focusedID == id,
                              let tab = navigation.controlTargets(in: window).first(where: { $0.id == id }) else { return false }
                        return navigation.focusRingFrame(in: window) == tab.frame
                    }
                    XCTAssertEqual(fixture.model.home.group, expected)
                    XCTAssertEqual(navigation.focusedID, id, "肩键切页后焦点应与新 tab 同步，包括空分组")
                    let tab = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == id })
                    XCTAssertEqual(navigation.focusRingFrame(in: window), tab.frame)
                }
                navigation.focus("card.fixture")
                pad.leftShoulder.setValue(1); navigation.source.tick(now: time)
                pad.leftShoulder.setValue(0); navigation.source.tick(now: time + 0.01)
                try await waitUntil { fixture.model.home.group == .favorites && navigation.focusedID == "home.group.favorites" }
                XCTAssertEqual(fixture.model.home.group, .favorites)
                XCTAssertEqual(navigation.focusedID, "home.group.favorites", "从卡片切页也应聚焦新 tab")
                navigation.source.controllers = { [] }
            }
        }
    }

    /// 首页：左右移动就是选中；焦点所在的卡片按 A = 主操作（同 R2 / ZR）。确认键界面一律显示 A（单只 Joy-Con 没有 ZR），按住不连发
    func testHomeConfirmOnFocusedCardRunsThePrimaryActionLikeRightTrigger() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogNeedsPreparation = true
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        let navigation = fixture.model.gamepad
        navigation.source.controllers = { [] }
        let (host, window) = try await render(AnyView(LauncherView(model: fixture.model, brand: "Original R2 fixture")
            .frame(width: 1120, height: 630)), fixture: fixture, language: .zh)
        navigation.attach(window); navigation.source.stop(); navigation.source.isActive = { true }
        defer { navigation.detach(); window.close() }
        let controller = GCController.withExtendedGamepad(), pad = try XCTUnwrap(controller.extendedGamepad)
        navigation.source.controllers = { [controller] }; navigation.source.tick(now: 0)
        navigation.focus("card." + game.id)
        fixture.model.selectedID = game.id
        XCTAssertEqual(navigation.shortcutTargets(in: window)[.rightTrigger], ["hero.export"])
        try snapshot(host, "home-r2-prepare")
        pad.buttonA.setValue(1); navigation.source.tick(now: 0.01)
        XCTAssertEqual(fixture.model.exportFor, game.id, "卡片按 A 执行主操作（准备游戏），同 R2")
        try await Task.sleep(for: .milliseconds(150))
        navigation.source.tick(now: 0.8)
        XCTAssertFalse(fixture.runner.requests.contains { $0["operation"] as? String == "export" },
            "按住 A 从首页进入出包页，不能再触发新页面的开始出包")
    }

    /// v0.5.0 手柄验收 A1：首页横向封面，手柄左右切游戏，选中的游戏（大图与标题）跟着换。注入 GCController 十字键，走生产输入路径
    func testAcceptanceHomeDpadSwitchesTheSelectedGame() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogGameCount = 3
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        let navigation = fixture.model.gamepad
        navigation.source.controllers = { [] }
        let (host, window) = try await render(AnyView(LauncherView(model: fixture.model, brand: "Original UI fixture")
            .frame(width: 1280, height: 760)), fixture: fixture, language: .zh)
        navigation.attach(window); navigation.source.stop(); navigation.source.isActive = { true }
        defer { navigation.detach(); window.close() }
        let controller = GCController.withExtendedGamepad(), pad = try XCTUnwrap(controller.extendedGamepad)
        navigation.source.controllers = { [controller] }; navigation.source.tick(now: 0)
        fixture.model.selectedID = "fixture"; navigation.focus("card.fixture")
        try await Task.sleep(for: .milliseconds(120))
        try snapshot(host, "acceptance-A1-0")
        var now = 0.01
        for expected in ["fixture-1", "fixture-2"] {
            pad.dpad.setValueForXAxis(1, yAxis: 0); navigation.source.tick(now: now); now += 0.01
            pad.dpad.setValueForXAxis(0, yAxis: 0); navigation.source.tick(now: now); now += 0.01
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(fixture.model.selectedID, expected, "十字键右一下切到下一款")
            XCTAssertEqual(navigation.focusedID, "card." + expected)
            try snapshot(host, "acceptance-A1-" + expected)
        }
        pad.dpad.setValueForXAxis(-1, yAxis: 0); navigation.source.tick(now: now); now += 0.01
        pad.dpad.setValueForXAxis(0, yAxis: 0); navigation.source.tick(now: now)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.model.selectedID, "fixture-1", "十字键左一下切回上一款")
    }

    /// v0.5.0 手柄验收 A6：玩过的游戏首页显示游玩时长（单独一块）；没玩过的不显示
    func testAcceptanceHomeShowsPlaytimeOnlyForPlayedGames() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogGameCount = 2
        fixture.runner.catalogPlaytime = ["seconds": 9059, "lastPlayed": Date().timeIntervalSince1970 - 86_400]
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.model.games.first { $0.id == "fixture" }?.playtime?.seconds, 9059)
        XCTAssertNil(fixture.model.games.first { $0.id == "fixture-1" }?.playtime)
        fixture.model.gamepad.source.controllers = { [] }
        for (id, played) in [("fixture", true), ("fixture-1", false)] {
            fixture.model.selectedID = id
            let (host, window) = try await render(AnyView(LauncherView(model: fixture.model, brand: "Original UI fixture")
                .frame(width: 1280, height: 760)), fixture: fixture, language: .zh)
            defer { window.close() }
            XCTAssertEqual(fixture.model.games.first { $0.id == id }?.playtime != nil, played, played ? "玩过的带游玩时长（首页那块按它显示，截图为证）" : "没玩过的不带")
            try snapshot(host, "acceptance-A6-" + id)
        }
    }

    func testTitlebarActionsAlignWithTheHomeControls() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        fixture.model.gamepad.source.controllers = { [] }
        for language in Lang.all {   // 六种界面语言都要（W1：英 / 日 / 西 / 法默认宽度下顶栏按钮压住品牌名）
            for width: CGFloat in [800, 1120, 1440] {
                let page = AnyView(LauncherView(model: fixture.model, brand: "Original UI fixture").frame(width: width, height: 630))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                // The native titlebar has its own hosting view; it registers its controls on a later main-loop pass.
                try await waitUntil {
                    let ids = Set(fixture.model.gamepad.controlTargets(in: window).map(\.id))
                    return ids.contains("top.report") && ids.contains("home.refresh")
                }
                let targets = fixture.model.gamepad.controlTargets(in: window)
                let report = try XCTUnwrap(targets.first { $0.id == "top.report" })
                let refresh = try XCTUnwrap(targets.first { $0.id == "home.refresh" })
                let bounds = window.convertToScreen(host.bounds)
                print("titlebar-right-edge \(language.code)/\(width): report=\(bounds.maxX - report.frame.maxX), home=\(bounds.maxX - refresh.frame.maxX)")
                XCTAssertEqual(report.frame.maxX, refresh.frame.maxX, accuracy: 0.5, "报修按钮应与游戏库控件共用右边缘")
                XCTAssertEqual(bounds.maxX - report.frame.maxX, LauncherTheme.Space.section, accuracy: 0.5)
                try snapshot(host, "titlebar-alignment-\(language.code)-\(Int(width))")
            }
        }
    }

    func testInlineTitlebarKeepsLongBrandAwayFromNativeActions() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        fixture.model.gamepad.source.controllers = { [] }
        for language in Lang.all {   // 六种界面语言都要（W1：英 / 日 / 西 / 法默认宽度下顶栏按钮压住品牌名）
            for width: CGFloat in [800, 1120, 1440] {
                let page = AnyView(LauncherView(model: fixture.model,
                    brand: "Original launcher title with a deliberately long name").frame(width: width, height: 630))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                for backgroundTask in [false, true, false] {
                    fixture.model.session = backgroundTask ? JobSession(kind: .play, gameID: "fixture", name: "Original task") : nil
                    fixture.model.sessionHidden = backgroundTask
                    // The native titlebar has its own hosting view. Its layout
                    // and the page's inset update on separate main-loop passes.
                    for _ in 0..<100 {
                        let ready = fixture.model.gamepad.controlTargets(in: window)
                        if let brand = ready.first(where: { $0.id == "top.brand" }),
                           let action = ready.filter({ $0.id.hasPrefix("top.") && $0.id != "top.brand" }).min(by: { $0.frame.minX < $1.frame.minX }),
                           ready.contains(where: { $0.id == "top.currentTask" }) == backgroundTask,
                           brand.frame.maxX + 12 <= action.frame.minX { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let targets = fixture.model.gamepad.controlTargets(in: window)
                    let brand = try XCTUnwrap(targets.first { $0.id == "top.brand" })
                    let action = try XCTUnwrap(targets.filter { $0.id.hasPrefix("top.") && $0.id != "top.brand" }.min { $0.frame.minX < $1.frame.minX })
                    let bounds = window.convertToScreen(host.bounds)
                    print("titlebar-heading \(language.code)/\(width)/\(backgroundTask): gap=\(action.frame.minX - brand.frame.maxX), fitting=\(host.fittingSize.width)")
                    XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
                    XCTAssertGreaterThanOrEqual(brand.frame.minX - bounds.minX, 89)
                    XCTAssertLessThanOrEqual(brand.frame.maxX + 12, action.frame.minX, "长品牌名不能覆盖原生标题栏操作")
                    XCTAssertGreaterThan(brand.frame.width, 2)
                    try snapshot(host, "titlebar-long-\(language.code)-\(Int(width))-\(backgroundTask)")
                }
            }
        }
    }

    func testHomeSearchDismissesOutsideClicksAndFocusLossWithoutClearingTheQuery() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let state = SearchControlState()
        let (host, window) = try await render(AnyView(SearchControlPreview(state: state)), fixture: fixture, language: .zh)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let navigation = fixture.navigation
        navigation.source.controllers = { [] }
        navigation.attach(window)
        defer { navigation.detach() }
        navigation.focus("home.search"); navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(state.expanded)
        XCTAssertTrue(window.firstResponder is NSTextView, "展开后应聚焦原生输入框")
        state.query = "Original"
        try await Task.sleep(for: .milliseconds(80))
        let clear = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "home.search.clear" })
        let clearFrame = window.convertFromScreen(clear.frame)
        try click(CGPoint(x: clearFrame.midX, y: clearFrame.midY), in: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.expanded, "点击胶囊内的清空按钮不能收起")
        XCTAssertEqual(state.query, "")
        state.query = "Original"
        let outside = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "search-test.outside" })
        let outsideFrame = window.convertFromScreen(outside.frame)
        try click(CGPoint(x: outsideFrame.midX, y: outsideFrame.midY), in: window)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(state.expanded, "点击搜索框外应自动收起")
        XCTAssertEqual(state.outsideClicks, 1, "收起搜索不能吞掉外部按钮的点击")
        XCTAssertEqual(state.query, "Original", "自动收起应保留查询")
        state.expanded = true
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(state.expanded, "键盘焦点移出搜索框后应自动收起")
        XCTAssertEqual(state.query, "Original")
        state.expanded = true
        try await Task.sleep(for: .milliseconds(350))
        try click(CGPoint(x: 20, y: 20), in: window)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(state.expanded, "点击非焦点控件的空白处也应收起")
        try snapshot(host, "home-search-dismissed")
    }

    func testCollapsedSearchIconDoesNotChangeWhenTheQueryIsNonempty() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let state = SearchControlState()
        let (host, window) = try await render(AnyView(SearchControlPreview(state: state)), fixture: fixture, language: .zh)
        defer { window.close() }
        let target = try XCTUnwrap(fixture.navigation.controlTargets(in: window).first { $0.id == "home.search" })
        let rect = host.convert(window.convertFromScreen(target.frame), from: nil)
        func pixels() throws -> Data {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let empty = try pixels()
        state.query = "Original"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try pixels(), empty, "收起时查询非空不能在放大镜上添加圆点")
        try snapshot(host, "home-search-query-without-badge")
    }

    private func click(_ point: CGPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
    }

    /// 屏幕键盘已出现且面板上的按键已登记（可以按键 / 提交）
    private func keyboardReady(_ navigation: LauncherPadNavigation) -> Bool {
        guard let k = navigation.keyboard else { return false }
        return navigation.activeWindow === k.panel && navigation.controlTargets(in: k.panel).contains { $0.id == "pad.key.q" }
    }

    private func waitUntil(_ ready: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ready(), "界面未在 2 秒内完成状态切换", file: file, line: line)
    }

    func testHomeSearchExpandsInsideTheHomeWindowAndKeepsItsQuery() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogGameCount = 21
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let navigation = fixture.model.gamepad
        navigation.source.controllers = { [] }
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1000, 1120, 1440] {
                fixture.model.home.search = ""
                let page = AnyView(LauncherView(model: fixture.model, brand: "Original UI fixture").frame(width: width, height: 630))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                navigation.attach(window)
                navigation.source.stop()
                window.makeKeyAndOrderFront(nil)
                defer { navigation.detach(); window.close() }
                func settleSearch() async throws {
                    var previous = CGRect.null
                    var stable = 0
                    try await waitUntil {
                        guard let frame = navigation.controlTargets(in: window).first(where: { $0.id == "home.search" })?.frame else { return false }
                        stable = frame == previous ? stable + 1 : 0
                        previous = frame
                        return stable >= 8
                    }
                }
                func toggleSearch() async throws {
                    try await settleSearch()
                    let target = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "home.search" })
                    let rect = window.convertFromScreen(target.frame)
                    try click(CGPoint(x: rect.midX, y: rect.midY), in: window)
                }
                let initialWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
                XCTAssertFalse(navigation.controlTargets(in: window).contains { $0.id == "home.filter" }, "首页不再显示重复的筛选按钮")
                try await toggleSearch()
                // Let the 240 ms capsule transition finish before the next mouse hit test.
                try await Task.sleep(for: .milliseconds(300))
                try await waitUntil {
                    navigation.controlTargets(in: window).contains { $0.id == "home.search.field" }
                        && window.firstResponder is NSTextView
                }
                let field = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "home.search.field" }, "搜索框应直接在首页展开")
                XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)), initialWindows, "展开搜索不能创建 popup")
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "鼠标展开后必须直接接受文本输入")
                editor.insertText("Original", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(fixture.model.home.search, "Original", "输入必须写回真实首页查询")
                XCTAssertTrue(window.convertToScreen(host.bounds).contains(field.frame))
                for id in ["home.search", "home.refresh", "library.sgradeUpgrade", "home.group.all", "home.group.ready", "home.group.recent", "home.group.favorites"] {
                    let control = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == id })
                    XCTAssertTrue(window.convertToScreen(host.bounds).contains(control.frame), "\(language)/\(width): 展开后控件必须留在窗口内")
                    XCTAssertLessThanOrEqual(control.frame.height, 44, "\(language)/\(width): 首页控件不能被换行撑高")
                }
                fixture.model.home.search = "Original"
                try await Task.sleep(for: .milliseconds(80))
                try snapshot(host, "home-search-expanded-\(language.code)-\(Int(width))")
                try await toggleSearch()
                try await Task.sleep(for: .milliseconds(300))
                try await waitUntil { !navigation.controlTargets(in: window).contains { $0.id == "home.search.field" } }
                XCTAssertFalse(navigation.controlTargets(in: window).contains { $0.id == "home.search.field" })
                XCTAssertEqual(fixture.model.home.search, "Original", "收起搜索保留筛选条件")
                try await toggleSearch()
                try await Task.sleep(for: .milliseconds(300))
                try await waitUntil {
                    navigation.controlTargets(in: window).contains { $0.id == "home.search.clear" }
                        && window.firstResponder is NSTextView
                }
                try await settleSearch()
                navigation.focus("home.search.clear"); navigation.handle(.confirm)
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(fixture.model.home.search, "")
                XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == "home.search.field" }, "清空后保持展开")
                let groups = try ["all", "ready", "recent", "favorites"].map { id in
                    try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == "home.group." + id })
                }
                for pair in zip(groups, groups.dropFirst()) {
                    XCTAssertLessThanOrEqual(pair.0.frame.maxX, pair.1.frame.minX, "分组应按全部、已就绪、最近、收藏顺序排列")
                }
                navigation.focus("home.group.ready"); navigation.handle(.confirm)
                XCTAssertEqual(fixture.model.home.group.rawValue, "ready")
                fixture.model.home.group = .all
            }
        }
    }

    func testHomeSearchControllerOpensKeyboardAndRestoresTextFocus() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let navigation = fixture.model.gamepad
        navigation.source.controllers = { [] }
        for language in [Lang.zh, .en] {
            navigation.source.controllers = { [] }
            let (host, window) = try await render(AnyView(LauncherView(model: fixture.model, brand: "Original search fixture")
                .frame(width: 1120, height: 630)), fixture: fixture, language: language)
            window.makeKeyAndOrderFront(nil)
            navigation.attach(window); navigation.source.stop()
            defer { navigation.detach(); window.close() }
            let controller = GCController.withExtendedGamepad(), pad = try XCTUnwrap(controller.extendedGamepad)
            navigation.source.controllers = { [controller] }; navigation.source.isActive = { true }
            navigation.source.faceMapping = { _ in .identity }
            navigation.source.assignment = { PlayerAssignment() }
            navigation.source.tick(now: 0)
            navigation.focus("home.search")
            pad.buttonA.setValue(1); navigation.source.tick(now: 0.01)
            pad.buttonA.setValue(0); navigation.source.tick(now: 0.02)
            // 键盘出来还不够：要等键盘面板上的按键已登记（面板布局完），否则按键 / 提交落在半成品面板上，关键盘时焦点回不到输入框
            try await waitUntil { keyboardReady(navigation) && navigation.controlTargets(in: window).contains { $0.id == "home.search.field" } }
            let keyboard = try XCTUnwrap(navigation.keyboard, "手柄确认展开搜索时应自动弹出屏幕键盘")
            XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == "home.search.field" }, "键盘不能使搜索框失焦收起")
            XCTAssertTrue(navigation.activeWindow === keyboard.panel)
            keyboard.value = "Original"
            navigation.focus("pad.key.q"); navigation.handle(.confirm)
            XCTAssertEqual(keyboard.value, "Originalq")
            try snapshot(try XCTUnwrap(keyboard.panel.contentView), "search-keyboard-" + language.code)
            navigation.handle(.submit)
            try await waitUntil { navigation.keyboard == nil && navigation.focusedID == "home.search.field" && window.firstResponder is NSTextView }
            XCTAssertNil(navigation.keyboard)
            XCTAssertEqual(fixture.model.home.search, "Originalq")
            XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == "home.search.field" })
            XCTAssertEqual(navigation.focusedID, "home.search.field", "关闭键盘后，手柄焦点应回到输入框")
            XCTAssertTrue(window.firstResponder is NSTextView, "关闭键盘后恢复原生文本焦点")
            navigation.handle(.confirm)
            try await waitUntil { keyboardReady(navigation) }
            let cancelled = try XCTUnwrap(navigation.keyboard)
            cancelled.value = "discarded"
            navigation.handle(.back)
            try await waitUntil { navigation.keyboard == nil && window.firstResponder is NSTextView }
            XCTAssertEqual(fixture.model.home.search, "Originalq", "B 取消不改变查询")
            XCTAssertTrue(window.firstResponder is NSTextView)
            navigation.handle(.back)
            try await waitUntil { !navigation.controlTargets(in: window).contains { $0.id == "home.search.field" } }
            XCTAssertFalse(navigation.controlTargets(in: window).contains { $0.id == "home.search.field" })
            navigation.handle(.search)
            try await waitUntil { keyboardReady(navigation) }
            let shortcutKeyboard = try XCTUnwrap(navigation.keyboard, "搜索快捷键与搜索按钮共用屏幕键盘入口")
            let key = try XCTUnwrap(navigation.controlTargets(in: shortcutKeyboard.panel).first { $0.id == "pad.key.q" })
            let rect = shortcutKeyboard.panel.convertFromScreen(key.frame)
            let beforeClick = shortcutKeyboard.value
            try click(CGPoint(x: rect.midX, y: rect.midY), in: shortcutKeyboard.panel)
            XCTAssertEqual(shortcutKeyboard.value, beforeClick + "q", "点击屏幕键盘不能使下方搜索收起")
            XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == "home.search.field" })
            navigation.handle(.back)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(fixture.model.home.search, "Originalq")
            try snapshot(host, "search-controller-return-" + language.code)
        }
    }

    func testOnScreenKeyboardKeepsCompleteActionLabelsWithAndWithoutControllerHints() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let (_, window) = try await render(AnyView(Color.black.frame(width: 1120, height: 630)), fixture: fixture, language: .en)
        let navigation = fixture.navigation
        navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
        defer { navigation.detach(); window.close() }
        for language in [Lang.zh, .en] {
            let loc = Localizer(language)
            navigation.text = { loc.t($0) }
            navigation.editText(value: "Original", label: "Name") { _ in }
            let keyboard = try XCTUnwrap(navigation.keyboard)
            let controller = GCController.withExtendedGamepad()
            let pad = try XCTUnwrap(controller.extendedGamepad)
            navigation.source.controllers = { [controller] }
            navigation.source.isActive = { true }
            navigation.source.tick(now: 0)
            pad.leftTrigger.setValue(1); navigation.source.tick(now: 0.1)
            XCTAssertEqual(keyboard.value, "", "左扳机应清空屏幕键盘中的文字")
            keyboard.value = "Original"
            navigation.source.tick(now: 0.8)
            XCTAssertEqual(keyboard.value, "Original", "长按左扳机不能重复清空")
            pad.leftTrigger.setValue(0); navigation.source.tick(now: 0.9)
            for connected in [false, true] {
                navigation.presentation.connected = connected
                navigation.presentation.symbols = ControllerFaceMapping.identity.symbols(for: .playstation)
                try await Task.sleep(for: .milliseconds(120))
                let targets = navigation.controlTargets(in: keyboard.panel)
                let shortcuts = navigation.shortcutTargets(in: keyboard.panel)
                let clearShortcut = try XCTUnwrap(PadShortcut(rawValue: "leftTrigger"), "清空提示应支持左扳机")
                for (shortcut, key) in [(PadShortcut.tertiary, "space"), (.back, "cancel"), (.rightTrigger, "done"), (clearShortcut, "clear")] {
                    let id = try XCTUnwrap(shortcuts[shortcut]?.first)
                    let target = try XCTUnwrap(targets.first { $0.id == id })
                    let label = NSHostingView(rootView: Text(loc.t("home.keyboard." + key)).font(.manrope(13, .semibold)))
                    let needed = label.fittingSize.width + 32 + (connected ? 22 : 0)
                    let actual = (target.unclippedFrame ?? target.frame).width
                    print("keyboard-label \(language.code)/\(connected)/\(key): needed=\(needed) actual=\(actual)")
                    XCTAssertGreaterThanOrEqual(actual + 0.5, needed, "\(language.code)/\(key)：完整文字、图标与内边距必须放得下")
                }
                let bounds = keyboard.panel.convertToScreen(try XCTUnwrap(keyboard.panel.contentView).bounds)
                for target in targets {
                    XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(target.unclippedFrame ?? target.frame), "键盘不能裁切按钮")
                }
                try snapshot(try XCTUnwrap(keyboard.panel.contentView), "keyboard-labels-\(language.code)-\(connected)")
            }
            keyboard.close(apply: false)
        }
    }

    func testSigningIdentityUsesCardInsetsWithoutModeSwitch() async throws {
        let previous = UserDefaults.standard.object(forKey: S2ArmLauncherModel.teamCodeKey)
        UserDefaults.standard.set("fixture-team-id", forKey: S2ArmLauncherModel.teamCodeKey)
        defer { UserDefaults.standard.set(previous, forKey: S2ArmLauncherModel.teamCodeKey) }
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            for width: CGFloat in [680, 820] {
                let page = AnyView(ScrollView { InstallModeCard(model: fixture.model).padding(32) }.frame(width: width, height: 700)
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text).preferredColorScheme(.dark))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                let controls = fixture.navigation.controlTargets(in: window)
                let identity = try XCTUnwrap(controls.first { $0.id == "export.sign.mode" })
                XCTAssertFalse(controls.contains { $0.id.hasPrefix("env.installMode.") }, "导出不再是设置中的装法选项")
                let rightEdge = window.convertToScreen(host.bounds).maxX - 32 - LauncherTheme.Metrics.cardInset
                let delta = rightEdge - identity.frame.maxX
                print("signing-right-edge language=\(language.code) width=\(width) delta=\(delta)")
                XCTAssertEqual(delta, 0, accuracy: 0.5, "签名身份应沿用卡片内容的右边距")
                try snapshot(host, "signing-right-edge-\(language.code)-\(Int(width))")
            }
        }
    }

    func testReadyGroupShowsEmptyStateAndCanReturnToAllGames() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.runner.catalogNeedsPreparation = true
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.first?.needsPreparation != true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.model.games.count, 1)
        XCTAssertEqual(fixture.model.games.first?.needsPreparation, true)
        let navigation = fixture.model.gamepad
        navigation.source.controllers = { [] }
        for language in [Lang.zh, .en] {
            let page = AnyView(LauncherView(model: fixture.model, brand: "Original UI fixture").frame(width: 1120, height: 630))
            let (host, window) = try await render(page, fixture: fixture, language: language)
            navigation.attach(window)
            defer { navigation.detach(); window.close() }
            navigation.focus("home.group.ready"); navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(fixture.model.home.group.rawValue, "ready")
            let targets = navigation.controlTargets(in: window)
            XCTAssertTrue(targets.contains { $0.id == "home.showAll" })
            XCTAssertFalse(targets.contains { $0.id.hasPrefix("card.") || $0.id.hasPrefix("hero.") })
            try snapshot(host, "home-ready-empty-\(language.code)")
            navigation.focus("home.showAll"); navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(fixture.model.home.group, .all)
            XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == "card.fixture" }, "返回全部游戏后应恢复待准备的游戏卡片")
        }
    }

    func testSheetsFitCommonDisplayBudgets() {
        let displays: [(CGSize, CGSize)] = [
            (CGSize(width: 1440, height: 900), CGSize(width: 820, height: 700)),
            (CGSize(width: 1024, height: 720), CGSize(width: 820, height: 620)),
            (CGSize(width: 800, height: 600), CGSize(width: 736, height: 500))
        ]
        for (display, expected) in displays {
            let size = LauncherSheetSize.settings.fitted(to: display, height: 700)
            XCTAssertEqual(size.width, expected.width)
            XCTAssertEqual(size.height, expected.height)
        }
    }

    func testBackendDescriptionsAreConciseWhileLogsKeepTheirPunctuation() {
        let loc = Localizer(.zh)
        XCTAssertEqual(loc.backend("测试说明。"), "测试说明")
        XCTAssertEqual(loc.backendLine("▸ 测试说明。"), "▸ 测试说明。")
        XCTAssertEqual(loc.backend("等待中..."), "等待中...")
    }

    func testSigningGuideFailureIsReportedToTheCallingPage() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        var failure: Error?
        fixture.model.openSigningProject { failure = $0 }
        for _ in 0..<100 where failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(failure, "引导项目打开失败必须回到发起操作的设置页")
        XCTAssertNil(fixture.model.installError, "不能把设置页错误写进另一个安装弹窗")
    }

    func testLongConfirmationKeepsActionsOnScreen() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.model.games.count, 1)
        for language in [Lang.zh, .en] {
            let page = AnyView(DownstreamConfirmSheet(model: fixture.model, gameID: "fixture", zh: language == .zh).frame(height: 500))
            let (host, window) = try await render(page, fixture: fixture, language: language)
            defer { window.close() }
            XCTAssertLessThanOrEqual(host.bounds.height, (NSScreen.main?.visibleFrame.height ?? 900) - 100,
                                     "长说明应在内容区滚动，不能将操作推出屏幕")
            let bounds = window.convertToScreen(host.bounds)
            for id in ["downstream.original", "downstream.recommend"] {
                let control = try XCTUnwrap(fixture.navigation.controlTargets(in: window).first { $0.id == id }, "长说明不能隐藏 \(id)")
                XCTAssertTrue(bounds.contains(control.frame), "操作必须位于窗口内")
            }
            try snapshot(host, "confirmation-long-\(language.code)")
        }
    }

    func testDescriptionPresentationOmitsFullStopsAndPreservesEllipses() throws {
        // Catalogs and shared specs also serve other frontends. Check the Mac
        // presentation boundary rather than rewriting upstream translations.
        XCTAssertEqual(LauncherCopy.note("Original description."), "Original description")
        XCTAssertEqual(LauncherCopy.note("原始说明。"), "原始说明")
        XCTAssertEqual(LauncherCopy.note("Loading..."), "Loading...")
        func check(_ text: String, _ context: String) {
            let note = LauncherCopy.note(text)
            XCTAssertFalse(note.hasSuffix("。") || (note.hasSuffix(".") && !note.hasSuffix("...")), context)
        }
        for (language, catalog) in L10n.catalogs {
            for (key, text) in catalog {
                check(text, "\(language)/\(key)")
            }
        }
        for item in try GameSettingsSpec.macItems() {
            for language in ["zh-Hans", "en"] {
                check(item.detail(language), "\(item.id)/\(language)")
            }
        }
        let source = try GameSettingsSpec.url().deletingLastPathComponent().appendingPathComponent("experience.v1.json")
        let spec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        let launcher = try XCTUnwrap(spec["launcher"] as? [String: Any])
        for row in try XCTUnwrap(launcher["items"] as? [[String: Any]]) {
            for language in ["zh-Hans", "en"] {
                let text = try XCTUnwrap(row[language] as? String)
                check(text, "\(row["id"] ?? "")/\(language)")
            }
        }
    }

    func testUpgradeActionsStayVisibleInAShortWindow() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let games = (1...9).map { SGradeScanGame(["id": "original-\($0)", "name": "Original game \($0)", "program": "original", "total": 1, "iphone": true, "patches": ["fps": 1]]) }
        for language in [Lang.zh, .en] {
            let code = language == .zh ? "zh-Hans" : "en"
            let page = AnyView(SGradeUpgradeBody(games: games, failure: nil, zh: language == .zh, busy: false,
                x: { BackendText.launcherText("sgrade.upgrade." + $0, language: code) }, upgrade: { _ in }, close: {}).frame(height: 500))
            let (host, window) = try await render(page, fixture: fixture, language: language)
            defer { window.close() }
            let bounds = window.convertToScreen(host.bounds)
            let list = try XCTUnwrap(scrollViews(in: host).first { $0.hasVerticalScroller })
            XCTAssertGreaterThan(list.contentView.bounds.height, 60, "游戏列表不能被压成不可见的滚动区")
            XCTAssertGreaterThan(try XCTUnwrap(list.documentView).bounds.height, 100)
            for id in ["sgrade.upgrade.install", "sgrade.upgrade.export"] {
                let action = try XCTUnwrap(fixture.navigation.controlTargets(in: window).first { $0.id == id }, "升级操作必须始终可见")
                XCTAssertTrue(bounds.contains(action.frame))
            }
            try snapshot(host, "upgrade-short-\(language.code)")
        }
    }

    func testUpgradeRowsAndConfirmationUseConsistentAlignment() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let games = [
            SGradeScanGame(["id": "alpha", "name": "Original Alpha", "program": "original", "total": 4,
                            "patches": ["widescreen": 1, "fps": 1, "gfx": 1, "cheat": 1]]),
            SGradeScanGame(["id": "beta", "name": "Original Beta", "program": "original", "total": 3,
                            "patches": ["widescreen": 1, "fps": 1, "gfx": 1]])
        ]
        for language in [Lang.zh, .en] {
            let code = language == .zh ? "zh-Hans" : "en"
            let page = AnyView(SGradeUpgradeBody(games: games, failure: nil, zh: language == .zh, busy: false,
                x: { BackendText.launcherText("sgrade.upgrade." + $0, language: code) }, upgrade: { _ in }, close: {}))
            let (host, window) = try await render(page, fixture: fixture, language: language)
            defer { window.close() }
            let bounds = window.convertToScreen(host.bounds)
            let actions = fixture.navigation.controlTargets(in: window)
            XCTAssertEqual(actions.count, 1)
            let button = try XCTUnwrap(actions.first)
            print("upgrade-footer \(language.code): bottom=\(button.frame.minY - bounds.minY), right=\(bounds.maxX - button.frame.maxX)")
            XCTAssertEqual(button.frame.minY - bounds.minY, 16, accuracy: 1, "升级弹窗应使用与设置页一致的 16 pt 底边距")
            XCTAssertEqual(bounds.maxX - button.frame.maxX, 32, accuracy: 1)
            let document = try XCTUnwrap(scrollViews(in: host).first?.documentView)
            let bitmap = try XCTUnwrap(document.bitmapImageRepForCachingDisplay(in: document.bounds))
            document.cacheDisplay(in: document.bounds, to: bitmap)
            // Only the two gray descriptions occupy the right half; the title and names are on the left.
            var rows: [(firstY: Int, lastY: Int, minX: Int)] = []
            for y in 0..<bitmap.pixelsHigh {
                var first: Int?
                for x in (bitmap.pixelsWide / 2)..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) > 0.4 {
                        first = x; break
                    }
                }
                if let first {
                    if let last = rows.last, y - last.lastY <= 4 {
                        rows[rows.count - 1] = (last.firstY, y, min(last.minX, first))
                    } else { rows.append((y, y, first)) }
                }
            }
            rows = rows.filter { $0.lastY - $0.firstY >= 4 } // Ignore the thin row separator.
            XCTAssertEqual(rows.count, 2, "应能从实际渲染结果中找到两行优化说明")
            if rows.count == 2 {
                print("upgrade-description-left \(language.code): \(rows.map(\.minX))")
                XCTAssertEqual(rows[0].minX, rows[1].minX, accuracy: 2, "右侧说明文字应共用左边界")
            }
            try snapshot(host, "upgrade-aligned-\(language.code)")
        }
    }

    func testExportContentUsesABoundedWidthAlignedToTheLeft() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(fixture.model.games.first)
        for language in [Lang.zh, .en] {
            for width: CGFloat in [800, 1120, 1440, 1920] {
                let padFocus = PadFocus()
                let page = AnyView(ExportView(model: fixture.model, covers: CoverCache(), game: game, install: {})
                    .environmentObject(padFocus).padScope("main", padFocus)
                    .background(LauncherWindowMaterial()).foregroundStyle(LauncherTheme.Colors.text).preferredColorScheme(.dark)
                    .frame(width: width, height: 630))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                let bounds = window.convertToScreen(host.bounds)
                let targets = fixture.navigation.controlTargets(in: window)
                let cover = try XCTUnwrap(targets.first { $0.id == "export.cover" })
                let start = try XCTUnwrap(padFocus.frames["main"]?.first { $0.id == "export.start" })
                // 接鼠标、没接触控板的 Mac 是常显滚动条，要从可用宽度里扣掉它占的那条
                let expectedContentWidth = width - 96 - (scrollViews(in: host).first.map(scrollerReserve) ?? 0)
                print("export-bounded \(language.code)/\(width): left=\(cover.frame.minX - bounds.minX), right=\(width - start.frame.maxX)")
                XCTAssertEqual(cover.frame.minX - bounds.minX, 48, accuracy: 1, "出包内容与底栏共用 48 pt 左边距")
                XCTAssertEqual(width - start.frame.maxX, 48, accuracy: 1, "底栏操作应保持距窗口右边缘 48 pt")
                XCTAssertTrue(bounds.contains(cover.frame))
                XCTAssertTrue(CGRect(x: 0, y: 0, width: width, height: 630).contains(start.frame))
                fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window); fixture.navigation.source.stop()
                defer { fixture.navigation.detach() }
                fixture.navigation.focus("export.location")
                try await Task.sleep(for: .milliseconds(60))
                let location = try XCTUnwrap(fixture.navigation.controlTargets(in: window).first { $0.id == "export.location" })
                XCTAssertEqual(location.frame.maxX - cover.frame.minX, expectedContentWidth - 14, accuracy: 1, "存放位置行的右缘也应与内容对齐，只含行内的 14 pt 边距")
                fixture.navigation.hide()
                if let scroll = scrollViews(in: host).first, let document = scroll.documentView {
                    let clip = scroll.contentView
                    clip.scroll(to: CGPoint(x: 0, y: document.isFlipped ? 0 : max(0, document.bounds.height - clip.bounds.height)))
                    scroll.reflectScrolledClipView(clip)
                }
                try snapshot(host, "export-bounded-\(language.code)-\(Int(width))")
            }
        }
    }

    func testImportFooterUsesTheStandardSheetMargins() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            for kind in [ImportSheet.Kind.games, .keys] {
                fixture.model.showAddGames = kind == .games
                fixture.model.showKeys = kind == .keys
                let (host, window) = try await render(AnyView(ImportSheet(model: fixture.model, kind: kind)), fixture: fixture, language: language)
                let navigation = fixture.navigation
                navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
                defer { navigation.detach(); window.close() }
                for connected in [false, true] {
                    navigation.presentation.connected = connected
                    try await Task.sleep(for: .milliseconds(70))
                    let cancelID = try XCTUnwrap(navigation.shortcutTargets(in: window)[.back]?.first)
                    let cancel = try XCTUnwrap(navigation.controlTargets(in: window).first { $0.id == cancelID })
                    let bounds = window.convertToScreen(host.bounds)
                    print("import-footer \(language.code)/\(kind)/\(connected): right=\(bounds.maxX - cancel.frame.maxX), bottom=\(cancel.frame.minY - bounds.minY)")
                    XCTAssertEqual(bounds.maxX - cancel.frame.maxX, 32, accuracy: 1)
                    XCTAssertEqual(cancel.frame.minY - bounds.minY, 16, accuracy: 1, "取消按钮与其他弹窗共用 16 pt 底边距")
                    XCTAssertEqual(cancel.frame.height, 36, accuracy: 1, "普通弹窗仍使用普通控件高度")
                    XCTAssertTrue(bounds.contains(cancel.frame))
                    try snapshot(host, "import-footer-\(language.code)-\(kind)-\(connected ? "connected" : "disconnected")")
                }
                navigation.handle(.back)
                XCTAssertFalse(fixture.model.showAddGames)
                XCTAssertFalse(fixture.model.showKeys)
                XCTAssertFalse(fixture.runner.requests.contains { ["import", "keys"].contains($0["operation"] as? String ?? "") })
            }
        }
    }

    func testInstallRepairActionsShareOneColumnInBothLanguages() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.checkInstall("fixture")
        for _ in 0..<100 where fixture.model.installReadiness == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(fixture.model.installReadiness)
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(InstallView(model: fixture.model, gameID: "fixture")), fixture: fixture, language: language)
            defer { window.close() }
            let targets = fixture.navigation.controlTargets(in: window)
            let settings = try XCTUnwrap(targets.first { $0.id == "install.goSettings" })
            let xcode = try XCTUnwrap(targets.first { $0.id == "install.openXcode" })
            XCTAssertEqual(settings.frame.width, 106, accuracy: 1)
            XCTAssertEqual(xcode.frame.width, 106, accuracy: 1)
            XCTAssertEqual(settings.frame.union(xcode.frame).width, 220, accuracy: 1)
            XCTAssertEqual(settings.frame.midY, xcode.frame.midY, accuracy: 1)
            XCTAssertTrue(window.convertToScreen(host.bounds).contains(settings.frame.union(xcode.frame)))
            try snapshot(host, "install-repair-\(language.code)")
        }
    }

    func testSettingsPagesHaveRoomForDescriptionAndControls() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let pages: [(String, AnyView)] = [
                ("settings", AnyView(EnvironmentView(model: fixture.model))),
                ("launch", AnyView(LaunchSettingsSheet(model: fixture.model, gameID: "fixture"))),
                ("input", AnyView(InputSettingsSheet(model: fixture.model, gameID: "fixture")))
            ]
            for (name, page) in pages {
                let (host, window) = try await render(page, fixture: fixture, language: language)
                defer { window.close() }
                // 780 pt leaves >= 380 pt for prose beside a 220 pt control, card insets and page margins.
                XCTAssertGreaterThanOrEqual(host.bounds.width, 780, "\(name)/\(language.code): 设置页应有舒适的阅读宽度")
                try snapshot(host, "\(name)-\(language.code)")
            }
        }
    }

    func testLaunchChoicesAndActionsHaveTheSameTrailingEdge() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(LaunchSettingsSheet(model: fixture.model, gameID: "fixture")),
                                                fixture: fixture, language: language)
            defer { window.close() }
            let targets = fixture.navigation.controlTargets(in: window)
            let action = try XCTUnwrap(targets.first { $0.id == "launch.input" }, "手柄设置入口必须可操作")
            let choice = try XCTUnwrap(targets.first { $0.id == "launch.rumbleLevel" }, "震动强度必须可操作")
            XCTAssertEqual(choice.frame.maxX, action.frame.maxX, accuracy: 1,
                           "\(language.code): 下拉框不能越过同列按钮的右边界")
            XCTAssertEqual(choice.frame.width, action.frame.width, accuracy: 1,
                           "\(language.code): 同列下拉框与按钮等宽")
            let content = window.convertToScreen(host.bounds)
            XCTAssertLessThanOrEqual(choice.frame.maxX, content.maxX - 40, "控件与弹窗右缘保持安全边距")
        }
    }

    func testSettingsActionsShareOneColumnAndDropdownStaysInItsWindow() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let previous = UserDefaults.standard.object(forKey: "appLanguage")
        defer { UserDefaults.standard.set(previous, forKey: "appLanguage") }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(EnvironmentView(model: fixture.model)), fixture: fixture, language: language)
            fixture.navigation.source.controllers = { [] }
            fixture.navigation.attach(window)
            defer { fixture.navigation.detach(); window.close() }
            let targets = fixture.navigation.controlTargets(in: window)
            let open = try XCTUnwrap(targets.first { $0.id == "settings.library.open" })
            let change = try XCTUnwrap(targets.first { $0.id == "settings.library.change" })
            let picker = try XCTUnwrap(targets.first { $0.id == "settings.language" })
            XCTAssertEqual(open.frame.height, 36, accuracy: 0.5)
            XCTAssertEqual(change.frame.height, 36, accuracy: 0.5)
            XCTAssertEqual(picker.frame.height, 36, accuracy: 0.5)
            XCTAssertEqual(change.frame.maxX, picker.frame.maxX, accuracy: 1)
            XCTAssertEqual(change.frame.maxX - open.frame.minX, 220, accuracy: 1,
                           "两个操作共用 220 pt，不能挤占说明区域")
            fixture.navigation.focus("settings.language"); fixture.navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(100))
            let options = fixture.navigation.controlTargets(in: window).filter { $0.id.hasPrefix("dropdown.") }
            XCTAssertEqual(Set(options.map(\.id)), Set(([""] + Lang.all.map(\.code)).map { "dropdown." + $0 }),
                           "下拉列表必须在当前设置窗口内显示跟随系统与全部可用语言")
            let bounds = window.convertToScreen(host.bounds)
            for option in options { XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(option.frame)) }
            fixture.navigation.focus("dropdown." + language.code); fixture.navigation.handle(.confirm)
            for _ in 0..<20 where fixture.navigation.controlTargets(in: window).contains(where: { $0.id.hasPrefix("dropdown.") }) {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertFalse(fixture.navigation.controlTargets(in: window).contains { $0.id.hasPrefix("dropdown.") }, "选择后恢复页面操作")
        }
    }

    func testStoredTeamIdDoesNotPreventCollapsingTheGuide() async throws {
        let previous = UserDefaults.standard.object(forKey: S2ArmLauncherModel.teamCodeKey)
        UserDefaults.standard.set("fixture-team-id", forKey: S2ArmLauncherModel.teamCodeKey)
        defer { UserDefaults.standard.set(previous, forKey: S2ArmLauncherModel.teamCodeKey) }
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let page = AnyView(ScrollView { InstallModeCard(model: fixture.model).padding(32) }.launcherSheet())
        let (host, window) = try await render(page, fixture: fixture, language: .zh)
        fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window)
        defer { fixture.navigation.detach(); window.close() }
        XCTAssertTrue(fixture.navigation.controlTargets(in: window).contains { $0.id == "env.teamGuideOpen" })
        try snapshot(host, "signing-guide-expanded-zh")
        fixture.navigation.focus("env.teamManual"); fixture.navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fixture.navigation.controlTargets(in: window).contains { $0.id == "env.teamGuideOpen" }, "保存过 Team ID 也应能收起引导")
        fixture.navigation.focus("env.teamManual"); fixture.navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.navigation.controlTargets(in: window).contains { $0.id == "env.teamGuideOpen" })
        XCTAssertEqual(UserDefaults.standard.string(forKey: S2ArmLauncherModel.teamCodeKey), "fixture-team-id")
    }

    func testKeyboardClearIsSeparateFromRecordAndSavesOnlyThatBinding() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let (_, window) = try await render(AnyView(InputSettingsSheet(model: fixture.model, gameID: "fixture")), fixture: fixture, language: .en)
        fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window)
        defer { fixture.navigation.detach(); window.close() }
        let targets = fixture.navigation.controlTargets(in: window)
        let record = try XCTUnwrap(targets.first { $0.id == "input.keyboard.record" })
        let clear = try XCTUnwrap(targets.first { $0.id == "input.keyboard.clear" })
        XCTAssertEqual(record.frame.height, 36, accuracy: 1)
        XCTAssertEqual(clear.frame.width, 36, accuracy: 1)
        XCTAssertEqual(clear.frame.height, 36, accuracy: 1)
        XCTAssertLessThanOrEqual(record.frame.maxX, clear.frame.minX + 0.5, "清除与录入是两个独立点击区域")
        fixture.navigation.focus("input.keyboard.clear"); fixture.navigation.handle(.confirm)
        try await Task.sleep(for: .milliseconds(50))
        fixture.navigation.focus("input.save"); fixture.navigation.handle(.confirm)
        for _ in 0..<50 where !fixture.runner.requests.contains(where: { $0["operation"] as? String == "saveInput" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = try XCTUnwrap(fixture.runner.requests.first { $0["operation"] as? String == "saveInput" })
        let keyboard = try XCTUnwrap((request["config"] as? [String: Any])?["keyboard"] as? [String: Any])
        XCTAssertNil(keyboard["A"], "清除 A 后保存的配置不能保留旧绑定")
        XCTAssertEqual((keyboard["B"] as? [String: Any])?["code"] as? Int, 56, "B 的 Shift 绑定保持原样")
    }

    func testSliderAdjustsWithControllersAndHonorsDisabledState() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let value = LayoutSliderValue()
        for enabled in [true, false] {
            let preview = AnyView(LayoutSliderPreview(value: value, enabled: enabled).padding(32).launcherSheet(.compact, height: 160))
            let (_, window) = try await render(preview, fixture: fixture, language: .en)
            fixture.navigation.source.controllers = { [] }; fixture.navigation.attach(window)
            defer { fixture.navigation.detach(); window.close() }
            let target = fixture.navigation.controlTargets(in: window).first { $0.id == "preview.slider" }
            if enabled {
                XCTAssertEqual(try XCTUnwrap(target).frame.height, 36, accuracy: 1)
                fixture.navigation.focus("preview.slider"); fixture.navigation.handle(.right)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(value.value, 0.6, accuracy: 0.0001)
                fixture.navigation.handle(.left)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(value.value, 0.5, accuracy: 0.0001)
            } else {
                XCTAssertNil(target, "禁用滑块不能接收手柄调整")
                fixture.navigation.focus("preview.slider"); fixture.navigation.handle(.right)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(value.value, 0.5, accuracy: 0.0001)
            }
        }
    }

    func testInputAxisControlsFitTheSharedColumnAfterScrolling() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(InputSettingsSheet(model: fixture.model, gameID: "fixture")), fixture: fixture, language: language)
            defer { window.close() }
            let scroll = try XCTUnwrap(scrollViews(in: host).first { $0.hasVerticalScroller })
            let document = try XCTUnwrap(scroll.documentView)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let targets = fixture.navigation.controlTargets(in: window)
            for axis in InputConfig.axisTargets {
                let choice = try XCTUnwrap(targets.first { $0.id == "input.axis.source." + axis })
                let invert = try XCTUnwrap(targets.first { $0.id == "input.axis.invert." + axis })
                XCTAssertEqual(choice.frame.width, 124, accuracy: 1, "来源选择与反向开关必须共用 220 pt 操作列")
                XCTAssertEqual(choice.frame.maxX, window.convertToScreen(host.bounds).maxX - 52 - scrollerReserve(scroll), accuracy: 1)
                XCTAssertEqual(choice.frame.union(invert.frame).width, 172, accuracy: 1)
            }
            try snapshot(host, "input-axes-\(language.code)")
        }
    }

    func testAllUtilitySheetsRenderWithContainedControlsInBothLanguages() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.model.messages = [["id": "original-message", "text": ["zh-Hans": "原创界面检查消息", "en": "Original interface review message"]]]
        fixture.model.refresh()
        for _ in 0..<100 where fixture.model.games.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        for language in [Lang.zh, .en] {
            let uiLanguage = language == .zh ? "zh-Hans" : "en"
            fixture.model.updatePopup = ["kind": "available", "version": "1.0.0", "notes": ["sections": [
                ["title": "UI", "items": [["zh-Hans": "统一设置界面", "en": "Consistent settings"]]]]]]
            let pages: [(String, AnyView)] = [
                ("settings", AnyView(EnvironmentView(model: fixture.model))),
                ("launch-settings", AnyView(LaunchSettingsSheet(model: fixture.model, gameID: "fixture"))),
                ("input-settings", AnyView(InputSettingsSheet(model: fixture.model, gameID: "fixture"))),
                ("downstream", AnyView(DownstreamConfirmSheet(model: fixture.model, gameID: "fixture", zh: language == .zh))),
                ("storage", AnyView(FreeSpaceView(model: fixture.model, gameID: "fixture"))),
                ("saves", AnyView(SaveManageSheet(model: fixture.model, gameID: "fixture"))),
                ("certificate", AnyView(DevCertSheet(model: fixture.model))),
                ("import-games", AnyView(ImportSheet(model: fixture.model, kind: .games))),
                ("import-keys", AnyView(ImportSheet(model: fixture.model, kind: .keys))),
                ("install", AnyView(InstallView(model: fixture.model, gameID: "fixture"))),
                ("update", AnyView(UpdatePopupView(model: fixture.model, language: uiLanguage))),
                ("messages", AnyView(MessagesPanel(model: fixture.model, language: uiLanguage))),
                ("diagnostics", AnyView(UploadDiagnosticsSheet(model: fixture.model, gameID: nil, operations: nil, fallback: "") {})),
                ("upgrade", AnyView(SGradeUpgradeBody(games: [], failure: nil, zh: language == .zh, busy: false,
                    x: { BackendText.launcherText("sgrade.upgrade." + $0, language: uiLanguage) }, upgrade: { _ in }, close: {})))
            ]
            for (name, page) in pages {
                let (host, window) = try await render(page, fixture: fixture, language: language)
                for connected in [false, true] {
                    fixture.navigation.presentation.connected = connected
                    try await Task.sleep(for: .milliseconds(70))
                    let bounds = window.convertToScreen(host.bounds)
                    XCTAssertLessThanOrEqual(host.bounds.height, (NSScreen.main?.visibleFrame.height ?? 900) - 100,
                                             "\(name)/\(language.code): 弹层必须适合屏幕")
                    if name == "update" || name == "messages" {
                        let reading = try XCTUnwrap(scrollViews(in: host).first { $0.hasVerticalScroller })
                        XCTAssertGreaterThan(reading.contentView.bounds.height, 40, "\(name): 说明列表必须有可见空间")
                    }
                    for target in fixture.navigation.controlTargets(in: window) {
                        XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(target.frame),
                                      "\(name)/\(language.code): 控件溢出 \(target.id) \(target.frame), \(bounds)")
                    }
                    if name != "messages" {
                        let shortcuts = fixture.navigation.shortcutTargets(in: window)
                        XCTAssertNil(shortcuts[.primary], "\(name)：确认键只操作焦点组件，提交动作应使用 R2")
                        if !["import-games", "import-keys"].contains(name) {
                            XCTAssertNotNil(shortcuts[.rightTrigger], "\(name)：确认／完成／启动操作必须登记 R2")
                        }
                        XCTAssertFalse(shortcuts.isEmpty, "\(name)/\(language.code)：弹窗底栏必须登记手柄快捷键")
                        for (key, ids) in shortcuts {
                            XCTAssertEqual(ids.count, 1, "\(name)/\(language.code)：同一按键不能同时触发多个底栏按钮：\(key) \(ids)")
                        }
                        if !["downstream", "import-games", "import-keys"].contains(name) {
                            XCTAssertNotNil(shortcuts[.back], "\(name)：必须能用 B 关闭或取消")
                        }
                    }
                    try snapshot(host, "\(name)-\(language.code)-\(connected ? "connected" : "disconnected")")
                }
                window.close()
            }
            for feature in [false, true] {
                fixture.model.updatePopup = feature
                    ? ["kind": "feature", "pages": [["title": ["zh-Hans": "原创说明", "en": "Original guide"]], ["title": ["zh-Hans": "第二页", "en": "Second page"]]]]
                    : ["kind": "afterUpdate", "version": "1.0.0", "notes": [:]]
                let page = feature ? AnyView(FeatureSpotlightView(model: fixture.model, language: uiLanguage))
                    : AnyView(UpdatePopupView(model: fixture.model, language: uiLanguage))
                let (host, window) = try await render(page, fixture: fixture, language: language)
                for connected in [false, true] {
                    fixture.navigation.presentation.connected = connected
                    try await Task.sleep(for: .milliseconds(70))
                    let keys = fixture.navigation.shortcutTargets(in: window)
                    XCTAssertEqual(keys[.rightTrigger]?.count, 1)
                    XCTAssertEqual(keys[.back]?.count, 1)
                    try snapshot(host, (feature ? "feature-" : "updated-") + language.code + (connected ? "-connected" : "-disconnected"))
                }
                window.close()
            }
        }
    }

    func testSettingsTabsExposeCategorizedControlsWithinBounds() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        for language in [Lang.zh, .en] {
            let (host, window) = try await render(AnyView(EnvironmentView(model: fixture.model)), fixture: fixture, language: language)
            fixture.navigation.source.controllers = { [] }
            fixture.navigation.attach(window)
            defer { fixture.navigation.detach(); window.close() }
            let expected: [(tab: String, controls: [String])] = [
                ("settings.tab.general", ["settings.language", "settings.library.open", "settings.keys.import"]),
                ("settings.tab.iphone", ["export.sign.mode", "env.cloud.choose"]),
                ("settings.tab.environment", ["settings.tab.environment"]),
                ("settings.tab.updates", ["settings.updates.check", "env.aiControl"]),
            ]
            for entry in expected {
                fixture.navigation.focus(entry.tab); fixture.navigation.handle(.confirm)
                try await Task.sleep(for: .milliseconds(80))
                let bounds = window.convertToScreen(host.bounds)
                for id in entry.controls {
                    fixture.navigation.focus(id)
                    try await Task.sleep(for: .milliseconds(50))
                    let targets = fixture.navigation.controlTargets(in: window)
                    XCTAssertTrue(targets.contains { $0.id == id }, "\(language.code)/\(entry.tab): 缺少控件 \(id)")
                }
                for target in fixture.navigation.controlTargets(in: window) {
                    XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(target.frame),
                                  "\(language.code)/\(entry.tab): 控件越界 \(target.id) \(target.frame) vs \(bounds)")
                }
            }
        }
    }

    func testSettingsSheetCentersVerticallyInsideParentWindow() async throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let host = NSHostingView(rootView: Text("Parent").frame(width: 1120, height: 630)
            .sheet(isPresented: .constant(true)) {
                EnvironmentView(model: fixture.model)
                    .environmentObject(Localizer(.zh))
            })
        let parent = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1120, height: 630),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.toolbar = NSToolbar(identifier: "settings.center.test")
        parent.toolbarStyle = .unified
        parent.contentView = host
        parent.orderBack(nil)
        defer { parent.close() }
        for _ in 0..<40 where parent.attachedSheet == nil { try await Task.sleep(for: .milliseconds(25)) }
        let sheet = try XCTUnwrap(parent.attachedSheet, "设置页必须作为 sheet 挂到父窗口")
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(30))
            if abs((parent.frame.maxY - sheet.frame.maxY) - (sheet.frame.minY - parent.frame.minY)) <= 2 { break }
        }
        let topGap = parent.frame.maxY - sheet.frame.maxY
        let bottomGap = sheet.frame.minY - parent.frame.minY
        print("settings-sheet parent=\(parent.frame) sheet=\(sheet.frame) topGap=\(topGap) bottomGap=\(bottomGap)")
        XCTAssertGreaterThanOrEqual(bottomGap, 60, "设置弹窗底部不能贴着外窗口底边")
        XCTAssertEqual(topGap, bottomGap, accuracy: 2, "设置弹窗应在外窗口中垂直居中")
    }

    private func exportArtworkBounds(_ host: NSView) throws -> CGRect {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<400 {
            for x in 0..<600 {
                guard let color = bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB),
                      color.redComponent - color.greenComponent > 0.5, color.blueComponent - color.greenComponent > 0.5 else { continue }
                xs.append(x); ys.append(y)
            }
        }
        let left = try XCTUnwrap(xs.min()), top = try XCTUnwrap(ys.min())
        return CGRect(x: left, y: top, width: try XCTUnwrap(xs.max()) - left + 1, height: try XCTUnwrap(ys.max()) - top + 1)
    }

    private func render(_ page: AnyView, fixture: SettingsFixture, language: Lang) async throws -> (NSView, NSWindow) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: page.environmentObject(Localizer(language))
            .environment(\.padControls, fixture.navigation).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: host.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        try await settle(window, fixture.navigation, fixture.model.gamepad)
        return (host, window)
    }

    /// 等页面布局稳定再量：手柄可操作的控件已登记、位置连续 3 次采样（约 90 ms）不变；一个控件都没有的页面，空着连续约 300 ms 也算稳。
    /// 设置类页面的控件登记在 fixture.navigation，首页（LauncherView）登记在 model.gamepad，两张表都看。
    /// 固定等 250 ms 在整套 / 门禁高负载下会量到还没登记的控件（XCTUnwrap 落空）或还在挪的位置（点歪、焦点框差几 pt）。最多等 5 秒，超时交给后面的断言报真实状态
    private func settle(_ window: NSWindow, _ registries: LauncherPadNavigation...) async throws {
        var last = "", same = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            let now = registries.flatMap { $0.controlTargets(in: window) }.map { "\($0.id)@\($0.frame)" }.joined(separator: ";")
            same = now == last ? same + 1 : 0
            if same >= (now.isEmpty ? 10 : 3) { return }
            last = now
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// 常显滚动条占掉的宽度（浮层滚动条为 0）。
    private func scrollerReserve(_ scroll: NSScrollView) -> CGFloat {
        scroll.bounds.width - scroll.contentView.frame.width
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func snapshot(_ host: NSView, _ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["S2A_SETTINGS_SHOTS"] else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
}

@MainActor private final class SearchControlState: ObservableObject {
    @Published var expanded = false
    @Published var query = ""
    var outsideClicks = 0
}

private struct SearchControlPreview: View {
    @ObservedObject var state: SearchControlState
    var body: some View {
        HStack {
            Spacer()
            Button("Outside") { state.outsideClicks += 1 }
                .controllerButtonStyle(.plain).controllerID("search-test.outside")
            HomeSearchControl(isExpanded: $state.expanded, text: $state.query, width: 300, edit: { finished in finished() })
        }
        .padding(30).frame(width: 600, height: 120).background(Color.black)
    }
}

@MainActor private final class SettingsFixture {
    let root: URL
    let model: S2ArmLauncherModel
    let navigation = LauncherPadNavigation()
    let runner = SettingsRunner()
    /// 模型想弹的提示框（标题：内容）：走记录不走真 NSAlert（runAlert 注入）
    private(set) var alerts: [String] = []
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-settings-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root,
            library: root.appendingPathComponent("library").path, libraryId: "layout-fixture"), runner: runner))
        quiet(model)
    }
    /// 这个夹具里建的模型（含重启后新建的）一律接上：提示框记下来，不弹真窗
    func quiet(_ m: S2ArmLauncherModel) { m.runAlert = { [weak self] a in self?.alerts.append(a.messageText + "：" + a.informativeText); return .alertSecondButtonReturn } }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class SettingsRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    private let lock = NSLock()
    private var captured: [[String: Any]] = []
    private var gameCount = 1
    private var needsPreparation = false
    private var cover = ""
    private var storage: [String: Any] = [:]
    var storageResponse: [String: Any] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    var catalogNeedsPreparation: Bool {
        get { lock.withLock { needsPreparation } }
        set { lock.withLock { needsPreparation = newValue } }
    }
    var catalogCover: String {
        get { lock.withLock { cover } }
        set { lock.withLock { cover = newValue } }
    }
    var catalogGameCount: Int {
        get { lock.withLock { gameCount } }
        set { lock.withLock { gameCount = newValue } }
    }
    private var downstreamChoice: String? = nil
    /// 夹具款上次选的下游方案（nil = 没选过；"" = 仍用原版）
    var catalogDownstreamChoice: String? {
        get { lock.withLock { downstreamChoice } }
        set { lock.withLock { downstreamChoice = newValue } }
    }
    private var playtime: [String: Any]? = nil
    var catalogPlaytime: [String: Any]? {
        get { lock.withLock { playtime } }
        set { lock.withLock { playtime = newValue } }
    }
    var requests: [[String: Any]] { lock.withLock { captured } }
    func start(executable: URL, arguments: [String], environment: [String: String], onLine: @escaping (Data) -> Void,
               onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments.last!))) as! [String: Any]
        lock.withLock { captured.append(request) }
        var result: [String: Any] = [:]
        if request["operation"] as? String == "locations" { result = storageResponse }
        if request["operation"] as? String == "catalog" {
            let copy: [String: Any] = [
                "zh": ["title": "选择运行方案", "body": "以下为原创布局说明，用于验证长内容滚动", "points": (1...24).map { "原创说明第 \($0) 项：此处展示较长的方案说明，以检查窗口与底部操作的边界" },
                       "recommend": "使用推荐方案", "original": "使用原版方案"],
                "en": ["title": "Choose a configuration", "body": "Original layout fixture for long content", "points": (1...24).map { "Original item \($0): a longer configuration description to verify scrolling and keep the actions visible" },
                       "recommend": "Use recommended", "original": "Use original"]]
            result = ["games": (0..<catalogGameCount).map { index in
                var game: [String: Any] = ["id": index == 0 ? "fixture" : "fixture-\(index)", "name": "Original UI fixture \(index)", "cover": catalogCover, "ready": true, "needsPreparation": catalogNeedsPreparation, "missing": [],
                 "downstream": ["id": "original-demo", "name": "Original Demo", "eligible": true, "copy": copy]]
                if index == 0, let playtime = catalogPlaytime { game["playtime"] = playtime }
                if let choice = catalogDownstreamChoice { game["downstream"] = ["id": "original-demo", "name": "Original Demo", "eligible": true, "copy": copy, "choice": choice] }
                return game
            }]
        }
        if request["operation"] as? String == "community" {
            var options: [String: Any] = [:]
            for item in try GameSettingsSpec.macItems() {
                options[item.id] = ["available": true, "hidden": item.group != "controls",
                                    "value": item.type == "choice" ? (item.options.first?.value ?? "") : true]
            }
            result = ["mac": options, "graphics": [], "cheats": ["items": []]]
        }
        if request["operation"] as? String == "installMode" { result = ["mode": "device"] }
        if request["operation"] as? String == "installCheck" {
            result = ["ready": true, "items": [["id": "appleId", "title": "Apple ID", "detail": "请在 Xcode 登录 Apple ID", "ok": false]]]
        }
        if request["operation"] as? String == "preflight" {
            result = ["checks": [["id": "xcode", "name": "Xcode", "ok": true, "group": "apple", "requiredFor": ["prepare", "launch", "ipa"]]]]
        }
        if request["operation"] as? String == "saveStatus" {
            result = ["hasSave": true, "fileCount": 3, "totalBytes": 20480]
        }
        if request["operation"] as? String == "spaceSurvey" {
            result = ["games": [["gameId": "fixture", "name": "Original UI fixture", "parts": [
                ["id": "shaders", "title": "着色器缓存", "rebuild": "下次启动时重新生成", "bytes": 1048576]],
                "kept": [["id": "saves", "bytes": 20480]]]]]
        }
        let failed = request["operation"] as? String == "signingProject"
        let event: [String: Any] = ["schema": 1, "taskId": request["taskId"] ?? "", "type": "result",
                                  "state": failed ? "failed" : "succeeded", "result": result,
                                  "message": failed ? "原创测试：引导项目暂不可用" : "", "code": failed ? "tool_missing" : ""]
        let data = try JSONSerialization.data(withJSONObject: event)
        DispatchQueue.main.async { onLine(data); onExit(0) }
        return Handle()
    }
}

@MainActor private final class LayoutSliderValue: ObservableObject {
    @Published var value = 0.5
}
private struct LayoutSliderPreview: View {
    @ObservedObject var value: LayoutSliderValue
    let enabled: Bool
    var body: some View {
        LauncherSlider(value: value.value, range: 0...1, step: 0.1) { value.value = $0 }
            .frame(width: 220).controllerID("preview.slider").disabled(!enabled)
    }
}
