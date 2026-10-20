import AppKit
import ClawdCore
import Combine

/// The widget's live state: config, probes, sessions, and everything the views show.
/// Ticks every `refreshSeconds` (upstream Update-Widget); a 1 s "kick" after start or a
/// manual refresh picks up the /usage reply before the full tick.
final class AppModel: ObservableObject {
    static let version = "1.0.0"

    let config = Config()
    let usageProbe = UsageProbe()
    let accountProbe = AccountProbe()
    let statusProbe = StatusProbe()
    let versionProbe = VersionProbe()
    let releaseProbe = ReleaseProbe()
    let weatherProbe = WeatherProbe()
    let remote = RemoteSessions()
    let mascot = MascotEngine()
    let sky = SkyEngine()
    let history = UsageHistory()
    lazy var advisor = Advisor(config: config)
    lazy var assistant = Assistant(config: config, advisor: advisor, claude: { [weak self] in self?.claudePath },
                                   usage: { [weak self] in self?.usage })
    lazy var clawdSession = ClawdSession(config: config, claude: { [weak self] in self?.claudePath })
    lazy var claudeSettings = ClaudeSettings()

    @Published var claudePath: String?
    @Published var sessions: [Session] = []
    @Published var theme = Theme.classic
    @Published var expanded = false
    @Published var tickCount = 0
    @Published var lastError = false
    @Published var releaseNotified = Set<String>()

    var onTick: [() -> Void] = []
    var onConfigChanged: [() -> Void] = []

    private var timer: Timer?
    private var kick: Timer?
    private var weatherPlaceKey = ""
    private var skinStamp = ""

    init() {
        I18n.lang = config.string("language")
        expanded = config.bool("expanded")
        ReleaseProbe.repo = config.string("updateRepo")
        theme = Theme.make(config.string("theme"), accent: config.string("accent"))
        claudePath = ClaudeLocator.find(configured: config.string("claudePath"))
        ReleaseProbe.repo = config.string("updateRepo")
        usageProbe.onSample = { [weak self] u in self?.history.add(u) }
        applySkin(force: true)
    }

    var usage: Usage? { usageProbe.usage }

    func start() {
        update()
        startKick()
        schedule()
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(2, config.double("refreshSeconds")), repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func startKick() {
        kick?.invalidate()
        kick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if !self.usageProbe.running { t.invalidate(); self.update() }
        }
    }

    /// Manual refresh from the menu: ask for everything now.
    func refreshNow() {
        if let c = claudePath { usageProbe.start(claude: c); accountProbe.start(claude: c) }
        statusProbe.start()
        startKick()
        update()
    }

    func update() {
        do { try updateInner(); lastError = false } catch {
            lastError = true
            ErrorLog.write("tick", "\(error)")
        }
    }

    private func updateInner() throws {
        if config.syncFromDisk() { configChanged() }
        let now = Date()
        if let c = claudePath {
            if now.timeIntervalSince(usageProbe.tried) >= config.double("usageIntervalSeconds") { usageProbe.start(claude: c) }
            if now.timeIntervalSince(versionProbe.tried) >= config.double("versionIntervalSeconds") {
                versionProbe.start(claude: c)
                releaseProbe.start()
            }
            if config.bool("showAccount") && now.timeIntervalSince(accountProbe.tried) >= config.double("accountIntervalSeconds") {
                accountProbe.start(claude: c)
            }
        }
        if let h = versionProbe.updating, !h.isRunning { versionProbe.updating = nil; versionProbe.reset() }
        if config.bool("showStatus") && now.timeIntervalSince(statusProbe.tried) >= config.double("statusIntervalSeconds") {
            statusProbe.start()
        }
        let place = "\(config.string("weatherLat"))|\(config.string("weatherLon"))"
        if place != weatherPlaceKey { weatherPlaceKey = place; weatherProbe.tried = .distantPast }
        if config.bool("showMascot") && config.bool("showSky") &&
            now.timeIntervalSince(weatherProbe.tried) >= config.double("weatherIntervalSeconds") {
            weatherProbe.start(config: config)
        }

        var ss: [Session] = []
        if config.bool("showSessions") || config.bool("showMascot") || config.bool("clawdSession") { ss = Sessions.local() }
        clawdSession.update(local: ss)
        let srcs = config.strings("remoteSessions")
        if !srcs.isEmpty { ss += remote.get(sources: srcs, refresh: config.double("refreshSeconds"), local: ss) }
        // Clawd's own session idling in his home is not "something running", or he would never sleep.
        let home = config.clawdHome.path
        let ownName = config.string("clawdSessionName")
        ss = ss.filter { !($0.name == ownName && $0.cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                            home.trimmingCharacters(in: CharacterSet(charactersIn: "/")) && !$0.busy && !$0.waiting) }
        sessions = ss
        if config.bool("showMascot") { mascot.setMood(sessions: ss, usage: usage, critPercent: config.double("critPercent")) }
        applySkin()
        let t = Theme.make(config.string("theme"), accent: config.string("accent"))
        if t != theme { theme = t }
        history.updateProjectsIfDue(enabled: config.bool("showHistory") && expanded)
        if advisor.update(), config.bool("showMascot") { mascotAttention("wave") }
        assistant.fireReminders()
        assistant.updateTasks()
        assistant.updateRemoteFeed()
        if releaseProbe.newer(than: Self.version), let r = releaseProbe.latest, !releaseNotified.contains(r.ver) {
            releaseNotified.insert(r.ver)
            let st = Paths.data("update-state.json")
            var j = JSONFile.readObject(st) ?? [:]
            if (j["notified"] as? String) != r.ver {
                j["notified"] = r.ver; JSONFile.write(j, to: st)
                Notifier.post(title: T("clawd.notifyTitle", r.ver), body: T("clawd.notifyText", r.ver), id: "release")
            }
        }
        for f in onTick { f() }
        tickCount += 1
    }

    /// Clawd waves or hops to draw attention, if he is free and awake.
    func mascotAttention(_ act: String) {
        guard config.bool("showMascot"), mascot.act == nil, mascot.mood != .dead, mascot.mood != .sleep else { return }
        mascot.startAct(act)
    }

    func configChanged() {
        I18n.lang = config.string("language")
        expanded = config.bool("expanded")
        ReleaseProbe.repo = config.string("updateRepo")
        theme = Theme.make(config.string("theme"), accent: config.string("accent"))
        schedule()
        applySkin(force: true)
        for f in onConfigChanged { f() }
        objectWillChange.send()
    }

    /// Writes one setting and applies it at once.
    func set(_ key: String, _ value: Any?) {
        config.set(key, value)
        configChanged()
        update()
    }

    func applySkin(force: Bool = false) {
        let all = Skins.all(home: config.clawdHome)
        let id = config.string("skin").lowercased()
        let s = all.first { $0.id == id } ?? .classic
        let key = "\(s.id)|\(s.layers.map { "\($0.color)\($0.px.count)" }.joined())|\(s.body)|\(s.eyes)"
        if force || key != skinStamp { skinStamp = key; mascot.skin = s }
    }

    func toggleDetails() {
        expanded.toggle()
        config.set("expanded", expanded)
    }

    // MARK: - display helpers

    var level: Level {
        guard let p = usage?.session else { return .dead }
        return config.level(Double(p))
    }

    var stale: Bool {
        guard let at = usageProbe.at else { return false }
        return Date().timeIntervalSince(at) > 3 * config.double("usageIntervalSeconds") + 30
    }

    var resetLine: String {
        guard let u = usage, u.session != nil else { return usageProbe.at == nil ? T("loading") : T("noData") }
        if let r = u.sessionReset {
            if let s = Fmt.span(to: r) { return T("reset.in", s) }
            return T("reset.closed")
        }
        return ""
    }

    func limitLine(_ pct: Int?, _ reset: Date?) -> String {
        guard let pct else { return T("noData") }
        var s = "\(pct)%"
        if let r = reset, let sp = Fmt.span(to: r) { s += "  ·  \(sp)" }
        return s
    }

    var trayTooltip: String {
        guard let u = usage, let pct = u.session else { return T("tray.noData") }
        if config.bool("trayResetClock") {
            var rows: [String] = []
            for (key, p, r) in [("tray.clock.session", u.session, u.sessionReset), ("tray.clock.week", u.week, u.weekReset),
                                ("tray.clock.fable", u.fable, u.fableReset)] {
                guard let p else { continue }
                var row = T(key, p)
                if let r { row += T("tray.clock.resets", Fmt.resetClock(r)) }
                rows.append(row)
            }
            return rows.joined(separator: "\n")
        }
        var tip = T("tray.session", pct)
        if let r = u.sessionReset, let s = Fmt.span(to: r) { tip += " · \(s)" }
        var t2: [String] = []
        if let w = u.week { t2.append(T("tray.week", w)) }
        if let f = u.fable { t2.append("Fable \(f)%") }
        if !t2.isEmpty { tip += "\n" + t2.joined(separator: " · ") }
        return tip
    }

    var sessionsLine: String {
        if sessions.isEmpty { return T("sess.none") }
        let busy = sessions.filter(\.busy).count, wait = sessions.filter(\.waiting).count
        var line = formatCount(sessions.count, "session")
        if busy > 0 || wait == 0 { line += "  ·  " + T("sess.busy", busy) }
        if wait > 0 { line += "  ·  " + T("sess.wait", wait) }
        return line
    }

    var statusDisplay: (dot: String, text: String, fg: String, extra: String) {
        let st = statusProbe.status
        let staleS = Date().timeIntervalSince(statusProbe.at) > 3 * config.double("statusIntervalSeconds") + 30
        guard let st, !staleS else {
            return (Palette.dead, statusProbe.status == nil ? T("st.loading") : T("st.offline"), theme.muted, "")
        }
        if st.indicator == "none" && st.broken.isEmpty && st.incidents.isEmpty {
            return (Palette.ok, T("st.ok"), theme.muted, "")
        }
        let dot = ["major", "critical"].contains(st.indicator) ? Palette.crit : Palette.warn
        let text = !st.incidents.isEmpty ? st.incidents.joined(separator: "  ·  ")
            : st.indicator == "maintenance" ? T("st.maint") : T("st.issues")
        let extra = st.broken.map { "\($0.name): \(TD("comp.\($0.state)", default: $0.state))" }.joined(separator: "  ·  ")
        return (dot, text, theme.text2, extra)
    }

    var stampLine: String {
        if lastError { return T("error") }
        guard let at = usageProbe.at else { return "" }
        let s = Fmt.clock(at, seconds: true)
        return stale ? "\(T("stale")) · \(s)" : s
    }

    var versionLine: (text: String, color: String) {
        guard let l = versionProbe.local else { return ("", theme.muted) }
        if versionProbe.updating != nil { return ("v\(l)  ·  \(T("ver.updating"))", Palette.warn) }
        if versionProbe.updateAvailable, let n = versionProbe.latest { return ("v\(l)  ·  \(T("ver.available", n))", Palette.warn) }
        if versionProbe.latest != nil { return ("v\(l)  ·  \(T("ver.latest"))", theme.muted) }
        return ("v\(l)", theme.muted)
    }

    var widgetVersionLine: (text: String, color: String, tip: String) {
        if releaseProbe.newer(than: Self.version), let r = releaseProbe.latest {
            let notes = r.notes.split(separator: "\n").prefix(20).joined(separator: "\n")
            return (T("clawd.available", r.ver), Palette.warn, "\(T("clawd.tipHead", Self.version, r.ver))\n\n\(notes)\n\n\(T("mac.releaseClick"))")
        }
        let text = (try? String(contentsOf: Paths.resource("CHANGELOG.md"), encoding: .utf8)) ?? ""
        let items = widgetChangelogSection(text, version: Self.version).map { "• \($0)" }
        return ("Clawd v\(Self.version)", theme.dim, "\(T("chg.clawdHead", Self.version))\n\n\(items.joined(separator: "\n"))\n\n\(T("chg.clawdClick"))")
    }

    var accountLine: (text: String, color: String) {
        guard config.bool("showAccount"), let a = accountProbe.account else { return ("", theme.faint) }
        if !a.loggedIn { return (T("acc.out"), Palette.crit) }
        return ([a.plan, a.email].filter { !$0.isEmpty }.joined(separator: "  ·  "), theme.faint)
    }

    /// Runs `claude update` in Terminal so the user sees it.
    func runClaudeUpdate() {
        guard let c = claudePath else { return }
        versionProbe.updating = ProcessRunner.run(c, ["update"], timeout: 600) { [weak self] r in
            self?.versionProbe.updating = nil
            self?.versionProbe.reset()
            if r.status != 0 { ErrorLog.write("claude update", String((r.stderr + r.stdout).prefix(400))) }
            self?.update()
        }
        update()
    }
}
