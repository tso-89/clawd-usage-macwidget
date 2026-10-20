import AppKit
import ClawdCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = AppModel()
    let anim = Animator()
    let tracker = MouseTracker()
    let badge = PanelBadge()
    var widget: FloatingPanel!
    var panel: FloatingPanel?
    var settings: SettingsWindow?
    var statusItem: NSStatusItem!
    var popups: RemindPopups!
    lazy var panelState = PanelState(model: model)

    func applicationDidFinishLaunching(_ note: Notification) {
        guard model.claudePath != nil else {
            let a = NSAlert()
            a.messageText = "Clawd Usage"
            a.informativeText = T("mac.noClaude")
            a.alertStyle = .critical
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        Notifier.setUp()
        Notifier.onClick = { [weak self] in self?.showPanel() }
        anim.model = model
        popups = RemindPopups(model: model)

        let a = model.assistant
        a.panelVisible = { [weak self] in self?.panel?.isVisible == true }
        a.onChange = { [weak self] in self?.assistantChanged() }
        a.notify = { title, body in Notifier.post(title: title, body: body) }
        a.mascotAct = { [weak self] act in self?.model.mascotAttention(act) }
        a.onReminderFired = { [weak self] r, done, text in
            guard let self else { return }
            self.popups.show(r, donePath: done, text: text)
            if !self.popups.canShow { Notifier.post(title: T("chat.remindTitle"), body: text) }
            self.panelState.remindDue += 1
            self.updateBadge()
        }
        model.advisor.onChange = { [weak self] in self?.updateBadge(); self?.panelState.objectWillChange.send() }
        model.onTick.append { [weak self] in self?.tick() }
        model.onConfigChanged.append { [weak self] in self?.applyWindowConfig() }

        makeStatusItem()
        makeWidget()
        model.start()
        anim.start()
        // For screenshots and the smoke test: open a window right away.
        switch ProcessInfo.processInfo.environment["CLAWD_SHOW"] {
        case "panel": showPanel()
        case "remind": showPanel(); panelState.tab = "remind"
        case "lists": showPanel(); panelState.tab = "lists"
        case "settings": showSettings()
        default: break
        }
        if ProcessInfo.processInfo.environment["CLAWD_READY_FILE"].map({ !$0.isEmpty }) == true {
            try? "\(AppModel.version) \(getpid())".write(toFile: ProcessInfo.processInfo.environment["CLAWD_READY_FILE"]!, atomically: true, encoding: .utf8)
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        saveWidgetPosition()
        model.clawdSession.shutdown()
    }

    // MARK: - widget window

    func makeWidget() {
        let w = FloatingPanel(keyable: false)
        w.delegate = self
        let actions = WidgetActions(togglePanel: { [weak self] in self?.togglePanel() },
                                    toggleSettings: { [weak self] in self?.toggleSettings() },
                                    hideWidget: { [weak self] in self?.hideWidget() })
        w.host(WidgetView(model: model, anim: anim, tracker: tracker, badge: badge, actions: actions), tracker: tracker)
        widget = w
        applyWindowConfig()
        if let l = model.config.optDouble("left"), let t = model.config.optDouble("top") {
            // Saved as the top-left corner in screen coordinates (y down from the top of the main screen).
            let mainH = NSScreen.screens.first?.frame.height ?? 900
            w.setFrameTopLeftPoint(NSPoint(x: l, y: mainH - t))
        } else if let v = NSScreen.main?.visibleFrame {
            w.setFrameTopLeftPoint(NSPoint(x: v.maxX - 282, y: v.maxY - 20))
        }
        clampToScreens()
        w.orderFrontRegardless()
    }

    func applyWindowConfig() {
        let desktop = model.config.bool("desktop")
        // Pinned: just above the desktop icons, so it still takes clicks, and stationary so
        // Mission Control and Show Desktop leave it in place.
        widget?.level = desktop ? NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : model.config.bool("topmost") ? .floating : .normal
        widget?.collectionBehavior = desktop ? [.canJoinAllSpaces, .stationary, .ignoresCycle]
            : [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel?.level = panelLevel
        widget?.alphaValue = CGFloat(max(0.15, min(1, model.config.double("opacity"))))
        (widget?.contentView as? AutoSizingHostingView<WidgetView>)?.scheduleResize()
        updateBadge()
    }

    /// The panel opens over normal windows even when the widget is pinned to the desktop.
    var panelLevel: NSWindow.Level { model.config.bool("desktop") ? .normal : widget.level }

    /// A display was disconnected or the position is off screen: bring the window back.
    func clampToScreens() {
        guard let w = widget else { return }
        let f = w.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f.insetBy(dx: 20, dy: 20)) }) { return }
        if let v = NSScreen.main?.visibleFrame { w.setFrameTopLeftPoint(NSPoint(x: v.maxX - f.width - 20, y: v.maxY - 20)) }
    }

    func windowDidMove(_ n: Notification) {
        guard (n.object as? NSWindow) === widget else { return }
        positionPanel()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveWidgetPosition), object: nil)
        perform(#selector(saveWidgetPosition), with: nil, afterDelay: 0.4)
    }

    /// No animation while the widget is fully covered or on another screen that is asleep.
    func windowDidChangeOcclusionState(_ n: Notification) {
        guard (n.object as? NSWindow) === widget else { return }
        if widget.occlusionState.contains(.visible) && widget.isVisible { anim.start() } else { anim.stop() }
    }

    func windowDidResize(_ n: Notification) {
        if (n.object as? NSWindow) === widget { positionPanel() }
    }

    @objc func saveWidgetPosition() {
        guard let w = widget else { return }
        let mainH = NSScreen.screens.first?.frame.height ?? 900
        model.config["left"] = Double(w.frame.minX).rounded()
        model.config["top"] = Double(mainH - w.frame.maxY).rounded()
        model.config.save()
    }

    func toggleWidget() {
        if widget.isVisible { hideWidget() } else { widget.orderFrontRegardless(); anim.start() }
    }

    func hideWidget() {
        widget.orderOut(nil)
        anim.stop()
        HoverTip.shared.hide(owner: UUID())
    }

    // MARK: - menu bar

    func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()
    }

    /// A little pixel Clawd for the menu bar, as a template image so macOS tints it for light and
    /// dark menu bars (the eyes are cut out, like Kiten's ✦ glyph it is one colour).
    static let menuBarIcon: NSImage = {
        let rows = ["...#############..", "...#############..", "...##.#######.##..", "...##.#######.##..",
                    ".#################", ".#################", "...#############..", "...#############..",
                    "...#.#.......#.#..", "...#.#.......#.#.."]
        let px: CGFloat = 1, py: CGFloat = 1.1
        let size = NSSize(width: 18 * px, height: CGFloat(rows.count) * py)
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() where c == "#" {
                    NSRect(x: CGFloat(x) * px, y: CGFloat(y) * py, width: px, height: py).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Clawd Usage"
        return img
    }()

    /// Clawd and the session percent. The number keeps the menu bar's own colour while all is well
    /// and turns yellow / red near the limit, so the colour only appears when it means something.
    func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        b.image = Self.menuBarIcon
        b.imagePosition = .imageLeft
        let pct = model.usage?.session
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: -0.5]
        if pct != nil, model.level == .warn || model.level == .crit { attrs[.foregroundColor] = NSColor(hex: Palette.level(model.level)) }
        b.attributedTitle = NSAttributedString(string: " " + (pct.map { "\($0)%" } ?? "--"), attributes: attrs)
        b.toolTip = model.trayTooltip
        b.setAccessibilityLabel("Clawd Usage, " + (pct.map { T("tray.session", $0) } ?? T("noData")))
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            let head = NSMenuItem(title: "clawd-usage-macwidget v\(AppModel.version)", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            menu.addItem(.separator())
            menu.addItem(item(T("menu.toggle"), #selector(menuToggle)))
            menu.addItem(item(T("menu.refresh"), #selector(menuRefresh)))
            menu.addItem(item(T("menu.settings"), #selector(menuSettings)))
            menu.addItem(.separator())
            menu.addItem(item(T("menu.exit"), #selector(menuQuit)))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleWidget()
        }
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }
    @objc func menuToggle() { toggleWidget() }
    @objc func menuRefresh() { model.refreshNow() }
    @objc func menuSettings() { showSettings() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    // MARK: - settings

    func toggleSettings() {
        if settings?.isVisible == true { settings?.orderOut(nil) } else { showSettings() }
    }

    func showSettings() {
        if settings == nil { settings = SettingsWindow(SettingsView(model: model, actions: settingsActions)) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    var settingsActions: SettingsActions {
        SettingsActions(lookNow: { [weak self] in self?.model.advisor.start() },
                        restartSession: { [weak self] in
                            guard let self else { return }
                            self.model.clawdSession.restart(local: Sessions.local())
                            self.model.update()
                        },
                        openSkins: { [weak self] in
                            guard let self else { return }
                            let d = self.model.config.clawdHome.appendingPathComponent("skins")
                            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                            Open.file(d)
                        })
    }

    // MARK: - Clawd's panel

    func togglePanel() {
        if panel?.isVisible == true { panel?.orderOut(nil); updateBadge() } else { showPanel() }
    }

    func showPanel() {
        if panel == nil {
            let p = FloatingPanel(keyable: true)
            p.isMovableByWindowBackground = false
            p.host(ClawdPanelView(state: panelState, model: model, close: { [weak self] in self?.togglePanel() }))
            panel = p
        }
        panel?.level = panelLevel
        model.assistant.unread = false
        panelState.remindDue = 0
        panelState.refresh()
        positionPanel()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        updateBadge()
    }

    /// Beside the widget: to its left if there is room, otherwise to its right.
    func positionPanel() {
        guard let p = panel, p.isVisible || p.frame.width > 0, let w = widget else { return }
        let size = p.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(w.frame) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? .zero
        var x = w.frame.minX - size.width - 8
        if x < v.minX { x = w.frame.maxX + 8 }
        var top = w.frame.maxY
        if top - size.height < v.minY { top = v.minY + size.height }
        p.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    }

    func assistantChanged() {
        panelState.refresh()
        updateBadge()
    }

    func tick() {
        updateStatusItem()
        updateBadge()
        if panel?.isVisible == true { panelState.refresh() }
        if widget.isVisible && widget.occlusionState.contains(.visible) { anim.start() }
    }

    /// The header icon: a bell - a reminder went off; a blue chat - Clawd answered;
    /// a lamp with a number - tips (yellow if urgent); a grey chat - nothing, just talk.
    func updateBadge() {
        let tips = model.advisor.tips()
        let a = model.assistant
        if panelState.remindDue > 0 {
            badge.icon = "bell.fill"; badge.count = "\(panelState.remindDue)"; badge.color = "#D77757"; badge.tip = T("chat.badgeRemind")
        } else if a.unread {
            badge.icon = "bubble.left.fill"; badge.count = ""; badge.color = "#60A5FA"; badge.tip = T("chat.badgeUnread")
        } else if !tips.isEmpty {
            badge.icon = "lightbulb"; badge.count = "\(tips.count)"; badge.tip = T("adv.badge", tips.count)
            badge.color = tips.contains(where: \.warn) ? Palette.warn : model.theme.muted
        } else {
            badge.icon = "bubble.left"; badge.count = ""; badge.color = model.theme.dim; badge.tip = T("chat.badge")
        }
        badge.visible = model.config.bool("showChat") || !tips.isEmpty || panelState.remindDue > 0
    }
}
