import Foundation

/// A chat message: user, clawd, note (from the widget), remind (a reminder fired).
public final class ChatMessage: Codable {
    public struct Run: Codable {
        public var script: String; public var state: String; public var code: Int32?
        public init(script: String, state: String, code: Int32?) { self.script = script; self.state = state; self.code = code }
    }
    public struct Grant: Codable { public var task: String; public var rules: [String]; public var state: String }
    public struct Call: Codable { public var tool: String; public var input: String }
    public struct Act: Codable { public var state: String; public var calls: [Call] }

    public var role: String
    public var text: String
    public var at: Date
    public var task: String?
    public var run: Run?
    public var grant: Grant?
    public var act: Act?
    public var remote: Bool?

    public init(role: String, text: String, at: Date = Date(), run: Run? = nil) {
        self.role = role; self.text = text; self.at = at; self.run = run
    }
}

/// Recurring tasks: files tasks/<name>.md in Clawd's home (upstream lib/tasks.ps1).
public struct ClawdTask: Equatable {
    public var name: String
    public var path: URL
    public var every: TimeInterval?
    public var everyText = ""
    public var at: [Int]?            // minutes from midnight, sorted
    public var atText = ""
    public var tools: [String] = []
    public var badTools: [String] = []   // `tools` entries that are not rules (see isToolRule); never passed on
    public var model = ""
    public var hours: (Int, Int)?
    public var limit: Int?
    public var paused = false
    public var prompt = ""

    public static func == (a: ClawdTask, b: ClawdTask) -> Bool { a.name == b.name && a.path == b.path && a.prompt == b.prompt }

    /// "10m", "2h", "1d", "30 мин" -> seconds; at least two minutes.
    public static func readEvery(_ s: String) -> TimeInterval? {
        guard let re = try? NSRegularExpression(pattern: #"^(\d+)\s*(m|min|mins|minutes?|м|мин\w*|h|hours?|ч|час\w*|d|days?|д|дн\w*|день)$"#) else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        let ns = t as NSString
        guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)), let n = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        let u = ns.substring(with: m.range(at: 2))
        let span = u.hasPrefix("m") || u.hasPrefix("м") ? n * 60 : u.hasPrefix("h") || u.hasPrefix("ч") ? n * 3600 : n * 86400
        return max(120, span)
    }

    /// "09:00, 18:00", "9", "9h30" -> sorted minutes of day; nil if any is not a time.
    public static func readAt(_ s: String) -> [Int]? {
        var list = Set<Int>()
        for w in s.components(separatedBy: CharacterSet(charactersIn: ",; \t")).filter({ !$0.isEmpty }) {
            guard let re = try? NSRegularExpression(pattern: #"^(\d{1,2})(?:[:.h](\d{2})|h)?$"#) else { return nil }
            let t = w.lowercased(); let ns = t as NSString
            guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
                  let h = Int(ns.substring(with: m.range(at: 1))), h <= 23 else { return nil }
            let mi = m.range(at: 2).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: 2))) ?? 99
            if mi > 59 { return nil }
            list.insert(h * 60 + mi)
        }
        return list.isEmpty ? nil : list.sorted()
    }

    /// "mcp__mail, Bash(gh issue list:*) WebFetch(domain:github.com)": a rule's parentheses may hold spaces.
    public static func splitTools(_ v: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"[^\s,()]+(?:\([^)]*\))?"#) else { return [] }
        let ns = v as NSString
        return re.matches(in: v, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// The only shapes a tool rule may take: an MCP server or tool, a site, web search, or a command by its
    /// first words. The rules go to claude as `--allowedTools` arguments, and a task file or a reply can be
    /// written by a prompt-injected model: no bare `Bash`, no `Bash(*)`, no shell punctuation, nothing like a flag.
    public static func isToolRule(_ s: String) -> Bool {
        s.range(of: #"^(?:mcp__[A-Za-z0-9][\w-]*(?:__[A-Za-z0-9][\w-]*)?|WebSearch|WebFetch\(domain:[A-Za-z0-9.-]+\)|Bash\([A-Za-z0-9/][\w./@+-]*(?: [\w./@+-]+)*:\*\))$"#,
                options: .regularExpression) != nil
    }

    public static func parse(_ raw: String, name: String, path: URL) -> ClawdTask {
        var t = ClawdTask(name: name, path: path, prompt: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let fm = ReminderStore.frontMatter(raw) else { return t }
        t.prompt = fm.body.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in fm.head.components(separatedBy: .newlines) {
            guard let r = line.range(of: #"^\s*(\w+)\s*:\s*(.*?)\s*$"#, options: .regularExpression) else { continue }
            let kv = line[r].split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let v = kv[1]
            switch kv[0].lowercased() {
            case "every": t.everyText = v; t.every = readEvery(v)
            case "at": t.atText = v; t.at = readAt(v)
            case "tools":
                let all = splitTools(v)
                t.tools = all.filter(isToolRule); t.badTools = all.filter { !isToolRule($0) }
            case "model": t.model = v
            case "paused": t.paused = ["yes", "true", "1", "да"].contains(v.lowercased())
            case "limit": if let l = v.firstMatch(#"^(\d{1,3})\s*%?$"#) { t.limit = Int(l) }
            case "hours":
                if let re = try? NSRegularExpression(pattern: #"^(\d{1,2})(?::00)?\s*-\s*(\d{1,2})(?::00)?$"#) {
                    let ns = v as NSString
                    if let m = re.firstMatch(in: v, range: NSRange(location: 0, length: ns.length)) {
                        t.hours = (Int(ns.substring(with: m.range(at: 1))) ?? 0, Int(ns.substring(with: m.range(at: 2))) ?? 24)
                    }
                }
            default: break
            }
        }
        return t
    }

    public func inHours(_ now: Date = Date()) -> Bool {
        guard let (a, b) = hours else { return true }
        let h = Calendar.current.component(.hour, from: now)
        return a <= b ? (h >= a && h < b) : (h >= a || h < b)   // across midnight: 22-7
    }

    /// The latest of the task's times that has come: today's, or yesterday's last one.
    public func slot(_ now: Date) -> Date? {
        guard let at, let last = at.last else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        let past = at.filter { day.addingTimeInterval(Double($0) * 60) <= now }
        if let p = past.last { return day.addingTimeInterval(Double(p) * 60) }
        return cal.date(byAdding: .day, value: -1, to: day)!.addingTimeInterval(Double(last) * 60)
    }

    public var whenText: String {
        if let at { return T("task.at", at.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }.joined(separator: ", ")) }
        if let e = every {
            if e >= 86400 && e.truncatingRemainder(dividingBy: 86400) == 0 { return T("task.everyD", Int(e / 86400)) }
            if e >= 3600 && e.truncatingRemainder(dividingBy: 3600) == 0 { return T("task.everyH", Int(e / 3600)) }
            return T("task.everyM", Int(e / 60))
        }
        return T("task.badEvery")
    }
}

/// Talking to Clawd and running his tasks (upstream lib/chat.ps1 + lib/tasks.ps1).
/// Each message is one headless `claude -p` in Clawd's home with a read-only tool set;
/// changes come back as fenced blocks the widget acts on.
public final class Assistant {
    // Only commands whose arguments cannot run or change anything: no `find` (-exec, -delete), mdfind instead.
    public static let readOnly = ["ls", "du", "df", "ps", "cat", "head", "tail", "stat", "file", "wc", "mdls", "mdfind",
                                  "launchctl list", "sw_vers", "system_profiler", "vm_stat", "uptime", "date", "top -l 1",
                                  "diskutil list", "diskutil info", "pmset -g", "defaults read", "sysctl", "uname", "whoami",
                                  "which", "brew list", "brew info", "pgrep", "lsof"]
    static let readVerbs = ["list", "get", "read", "search", "fetch", "find", "query", "view", "show"]
    static let taskSchema = #"{"type":"object","properties":{"tell":{"type":"boolean"},"message":{"type":"string"},"summary":{"type":"string"}},"required":["tell","message","summary"]}"#
    static let keep = 60
    static let autoChainMax = 3
    static let historyKeep = 20

    public let config: Config
    public let reminders: ReminderStore
    public let lists: ListStore
    public let advisor: Advisor
    public var claude: () -> String?
    public var usage: () -> Usage?
    public var panelVisible: () -> Bool = { false }

    // Hooks to the UI.
    public var onChange: (() -> Void)?
    public var notify: ((String, String) -> Void)?
    public var mascotAct: ((String) -> Void)?
    public var onReminderFired: ((Reminder, URL?, String) -> Void)?

    public private(set) var messages: [ChatMessage] = []
    public private(set) var sessionId = UUID().uuidString.lowercased()
    public private(set) var started = false
    public private(set) var since = Date.distantPast
    public var unread = false
    public private(set) var doing = ""
    public private(set) var chatStarted: Date?
    public private(set) var remoteItems: [ChatMessage] = []

    var chatHandle: ProcessRunner.Handle?
    var runHandle: ProcessRunner.Handle?
    var taskHandle: ProcessRunner.Handle?
    public private(set) var runningTask: String?
    var taskQueue: [String] = []
    var autoChain = 0
    var stoppedByUser = false
    var remotePath = ""
    var remoteOffset: UInt64 = 0

    public var chatBusy: Bool { chatHandle != nil }
    public var runBusy: Bool { runHandle != nil }

    var statePath: URL { config.dataFile("chat-state.json") }
    var tasksStatePath: URL { config.dataFile("tasks-state.json") }

    public init(config: Config, advisor: Advisor, claude: @escaping () -> String?, usage: @escaping () -> Usage?) {
        self.config = config
        self.advisor = advisor
        self.claude = claude
        self.usage = usage
        reminders = ReminderStore(home: { config.clawdHome })
        lists = ListStore(home: { config.clawdHome })
        load()
    }

    // MARK: - chat state

    struct State: Codable {
        var sessionId: String
        var started: Bool
        var since: Date?
        var messages: [ChatMessage]
    }

    func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: statePath), let s = try? dec.decode(State.self, from: d) {
            sessionId = s.sessionId; started = s.started; since = s.since ?? .distantPast; messages = s.messages
            // A script cannot outlive the widget: one "running" at exit is unknown now.
            for m in messages where m.run?.state == "running" { m.run?.state = "done" }
        }
    }

    public func save() {
        if messages.count > Self.keep { messages.removeFirst(messages.count - Self.keep) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(State(sessionId: sessionId, started: started, since: since, messages: messages)) {
            try? d.write(to: statePath, options: .atomic)
        }
        writeChatLog()
    }

    /// The panel's conversation as a file in Clawd's home, so his own session (the phone) knows it.
    func writeChatLog() {
        var lines = ["# Chat in the widget panel", "",
                     "The user talks to Clawd here too: in the panel of the clawd-usage-macwidget widget on the Mac.",
                     "Written by the widget, latest at the bottom; do not edit.", ""]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        for m in messages where ["user", "clawd", "remind"].contains(m.role) {
            let who = ["user": "User", "clawd": "Clawd", "remind": "Reminder fired"][m.role]!
            var text = m.text
            if let r = m.run { text += "\n[proposed a script: \(r.state)\(r.code.map { ", exit \($0)" } ?? "")]" }
            if let a = m.act { text += "\n[asked to use \(a.calls.map(\.tool).joined(separator: ", ")): \(a.state)]" }
            lines += ["**\(who)** \(df.string(from: m.at))", text, ""]
        }
        try? lines.joined(separator: "\n").write(to: config.clawdHome.appendingPathComponent("chat-log.md"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    public func add(_ role: String, _ text: String, run: ChatMessage.Run? = nil) -> ChatMessage {
        let m = ChatMessage(role: role, text: text, run: run)
        messages.append(m)
        save()
        onChange?()
        return m
    }

    /// The feed shown in the panel: this chat plus the phone conversation, by time.
    public var feed: [ChatMessage] {
        (messages + remoteItems).sorted { $0.at < $1.at }
    }

    /// "+": a new conversation here; the phone conversation so far is no longer shown.
    public func reset() {
        guard chatHandle == nil else { return }
        sessionId = UUID().uuidString.lowercased(); started = false; since = Date(); messages = []
        remoteItems = []
        save()
        onChange?()
    }

    // MARK: - reply blocks

    public struct Reply {
        public var text: String; public var run: ChatMessage.Run?; public var notes: [String]
        public var grants: [ChatMessage.Grant] = []   // tools a `task` block asked for: cards for the user
    }

    /// Pulls `run`, `remind`, `list-*`, `task` blocks out of a reply and acts on them.
    /// A model's `task` block never grants tools by itself: the task is written without them and the
    /// valid ones become an Allow card. `fromTask`: a task's own report, which may not make or remove tasks.
    public func readReply(_ reply: String, fromTask: Bool = false) -> Reply {
        var run: ChatMessage.Run?
        var notes: [String] = []
        var grants: [ChatMessage.Grant] = []
        let rx = try! NSRegularExpression(pattern: #"(?ms)^```(run|remind|remind-cancel|list-add|list-check|list-uncheck|list-remove|task|task-remove)[ \t]*\r?\n(.*?)^```[ \t]*$"#)
        let ns = reply as NSString
        for m in rx.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = body.components(separatedBy: .newlines)
            switch kind {
            case "run": if !body.isEmpty { run = .init(script: body, state: "pending", code: nil) }
            case "remind":
                for line in lines {
                    let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { continue }
                    let when = parts[0].split(separator: " ").map(String.init)
                    guard let first = when.first, let at = ReminderStore.parseAt(first) else { continue }
                    let rep = when.count > 1 && ReminderStore.repeats.contains(when[1].lowercased()) ? when[1].lowercased() : ""
                    reminders.create(at: at, text: parts[1], repeatRule: rep)
                    var set = ReminderStore.formatTime(at)
                    if !rep.isEmpty { set += ", \(T("rem.\(rep)"))" }
                    notes.append(T("chat.remindSet", set, parts[1]))
                }
            case "remind-cancel":
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let r = reminders.remove(line) { notes.append(T("chat.remindCancel", r.text)) }
                }
            case "list-add", "list-check", "list-uncheck", "list-remove":
                for line in lines {
                    let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
                    let list = ListStore.clean(parts[0]), item = parts[1]
                    var ok = true
                    switch kind {
                    case "list-add": lists.add(list, item)
                    case "list-check": ok = lists.setDone(list, item, true)
                    case "list-uncheck": ok = lists.setDone(list, item, false)
                    default: ok = lists.removeItem(list, item)
                    }
                    if ok { notes.append(T("chat.\(kind)", list, item)) }
                }
            case "task" where fromTask, "task-remove" where fromTask:
                notes.append(T("chat.taskFromTask"))
            case "task":
                let parts = body.components(separatedBy: "\n---").count > 1
                    ? (try? NSRegularExpression(pattern: #"(?m)^---[ \t]*$"#)).map { re -> [String] in
                        let bns = body as NSString
                        guard let mm = re.firstMatch(in: body, range: NSRange(location: 0, length: bns.length)) else { return [body] }
                        return [bns.substring(to: mm.range.location), bns.substring(from: mm.range.location + mm.range.length)]
                    } ?? [body] : [body]
                guard parts.count == 2 else { notes.append(T("chat.taskBad", "")); break }
                var head: [String: String] = [:]
                for l in parts[0].components(separatedBy: .newlines) {
                    let kv = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2 { head[kv[0].lowercased()] = kv[1] }
                }
                let prompt = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let every = head["every"].flatMap(ClawdTask.readEvery), at = head["at"].flatMap(ClawdTask.readAt)
                guard let name = head["name"], !name.isEmpty, every != nil || at != nil, !prompt.isEmpty else {
                    notes.append(T("chat.taskBad", head["name"] ?? "")); break
                }
                let asked = ClawdTask.splitTools(head.removeValue(forKey: "tools") ?? "")
                if let path = writeTask(name, head, prompt) {
                    var t = ClawdTask(name: path.deletingPathExtension().lastPathComponent, path: path)
                    t.every = every; t.at = at
                    notes.append(T("chat.taskSet", name, t.whenText))
                    let bad = asked.filter { !ClawdTask.isToolRule($0) }
                    if !bad.isEmpty { notes.append("[\(t.name)] " + T("task.badTools", bad.joined(separator: " "))) }
                    let rules = Array(Set(asked.filter(ClawdTask.isToolRule))).sorted()
                    if !rules.isEmpty { grants.append(.init(task: t.name, rules: rules, state: "pending")) }
                }
            case "task-remove":
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let t = removeTask(line.trimmingCharacters(in: .whitespaces)) { notes.append(T("chat.taskRemove", t.name)) }
                }
            default: break
            }
        }
        let text = Self.plain(rx.stringByReplacingMatches(in: reply, range: NSRange(location: 0, length: ns.length), withTemplate: ""))
        return Reply(text: text, run: run, notes: notes, grants: grants)
    }

    /// A card per task a reply made with `tools`: the task's text, so the user knows what they allow.
    func addGrantCards(_ rep: Reply) {
        for g in rep.grants {
            let prompt = findTask(g.task)?.prompt ?? ""
            let msg = add("clawd", T("chat.taskTools", g.task) + (prompt.isEmpty ? "" : "\n\n" + prompt))
            msg.task = g.task
            msg.grant = g
            save()
        }
    }

    /// The panel shows plain text: drop markdown emphasis and inline code marks.
    public static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(\r?\n){3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - context

    static func nowLine(_ now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        let tz = TimeZone.current.secondsFromGMT(for: now)
        return "\(f.string(from: now)) (UTC\(tz >= 0 ? "+" : "-")\(String(format: "%02d:%02d", abs(tz) / 3600, abs(tz) % 3600 / 60)))"
    }

    /// What Claude gets before each message: time, rights, tips, reminders, lists, tasks, recent reports.
    public func context() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let short = DateFormatter(); short.dateFormat = "MM-dd HH:mm"
        var lines = ["<context>", "now: \(Self.nowLine())", "computer: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "auto-run: \(config.bool("chatAutoRun") ? "on - your run scripts start at once, without the user's click" : "off")",
                     "full access: \(config.bool("chatBypass") ? "on - nothing is refused, read files anywhere on the Mac" : "off")"]
        let tips = advisor.tips()
        if tips.isEmpty { lines.append("tips: none") } else {
            lines.append("tips:")
            for t in tips { lines.append("- \(t.text)"); if let c = t.ctx { lines.append("  details: \(c)") } }
        }
        let rem = reminders.all()
        if rem.isEmpty { lines.append("reminders: none") } else {
            lines.append("reminders (file in the reminders folder - time - text):")
            for r in rem { lines.append("- \(r.rel) - \(df.string(from: r.at))\(r.repeatRule.isEmpty ? "" : " (repeats \(r.repeatRule))") - \(r.text)") }
        }
        let names = lists.names()
        if !names.isEmpty {
            lines.append("lists (files in the lists folder; \"[x]\" - ticked off):")
            for n in names {
                let items = lists.read(n).items.map { ($0.done ? "[x] " : "") + $0.text }
                lines.append("- \(n): \(items.isEmpty ? "empty" : items.joined(separator: "; "))")
            }
        }
        let ts = tasks()
        if !ts.isEmpty {
            let st = taskState()
            lines.append("recurring tasks (files in the tasks folder):")
            for t in ts {
                let last = st[t.name]?.last.map { short.string(from: $0) } ?? "never"
                var s = "- \(t.name): \(t.at != nil ? "at \(t.atText)" : "every \(t.everyText)")"
                if !t.tools.isEmpty { s += ", tools \(t.tools.joined(separator: " "))" }
                if let h = t.hours { s += ", hours \(h.0)-\(h.1)" }
                if t.paused { s += ", paused" }
                s += ", last run \(last) - \(t.prompt.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))"
                lines.append(s)
            }
        }
        let cut = Date().addingTimeInterval(-86400)
        let reports = messages.filter { $0.task != nil && $0.at > cut }.suffix(5)
        if !reports.isEmpty {
            lines.append("recent reports of your recurring tasks, shown to the user in this chat (the user may be replying to them):")
            for m in reports {
                var t = m.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                if t.count > 800 { t = String(t.prefix(800)) + "..." }
                lines.append("- \(short.string(from: m.at)) \(t)")
            }
        }
        let recent = remoteItems.suffix(12)
        if !recent.isEmpty {
            lines.append("recent conversation in your own session (the user on the phone via Remote Control):")
            for m in recent {
                var t = m.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                if t.count > 400 { t = String(t.prefix(400)) + "..." }
                lines.append("- \(short.string(from: m.at)) \(m.role == "user" ? "user" : "you"): \(t)")
            }
        }
        lines.append("</context>")
        return lines.joined(separator: "\n")
    }

    /// The chat's rules for the tasks' tools: in auto mode the whole server, otherwise only what reads.
    func toolRules(_ tools: [String]) -> [String] {
        var rules: [String] = []
        for t in tools {
            if config.bool("chatAutoRun") || !t.hasPrefix("mcp__") || t.range(of: #"^mcp__.+__"#, options: .regularExpression) != nil {
                rules.append(t); continue
            }
            for v in Self.readVerbs { rules.append("\(t)__\(v)_*") }
        }
        return rules
    }

    static var readOnlyRules: [String] { readOnly.map { "Bash(\($0):*)" } }

    /// chat-prompt.md for the current mode: `compact` or `full` parts, the other kind cut out.
    func promptFile() -> String {
        let drop = config.bool("chatCompact") ? "full" : "compact"
        var text = (try? String(contentsOf: Paths.resource("prompts/chat-prompt.md"), encoding: .utf8)) ?? ""
        text = text.replacingOccurrences(of: "(?s)<!-- \(drop) -->.*?<!-- /\(drop) -->\\r?\\n", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<!-- /?(compact|full) -->\r?\n"#, with: "", options: .regularExpression)
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-chat-prompt-\(getpid()).md")
        try? text.write(to: p, atomically: true, encoding: .utf8)
        return p.path
    }

    // MARK: - chat

    /// `hidden`: a message from the widget itself (a script's output). `allow`: tools for this one call.
    public func send(_ text: String, hidden: Bool = false, allow: [String] = []) {
        guard chatHandle == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let claude = claude() else { return }
        if !hidden {
            // A new word from the user replaces a script still waiting for approval.
            for m in messages {
                if m.run?.state == "pending" { m.run?.state = "replaced" }
                if m.act?.state == "pending" { m.act?.state = "replaced" }
            }
            autoChain = 0
            add("user", text)
        }
        let tools = Array(Set(tasks().flatMap(\.tools))).sorted()
        var ctx = context()
        if !tools.isEmpty {
            let how = config.bool("chatAutoRun") ? "all of them at once" : "reading at once; actions after the user approves them"
            ctx = ctx.replacingOccurrences(of: "</context>", with: "tools you may use besides reading: \(tools.joined(separator: " ")) (\(how))\n</context>")
        }
        var argv = ["-p", "--output-format", "stream-json", "--verbose", "--model", config.string("chatModel"),
                    "--permission-mode", config.bool("chatBypass") ? "bypassPermissions" : "default"]
        // MCP servers come from the user's own Claude Code config: loaded only when a task was given one.
        if !(tools + allow).contains(where: { $0.hasPrefix("mcp__") }) { argv.append("--strict-mcp-config") }
        argv += ["--disallowedTools", "Write", "Edit", "NotebookEdit", "--append-system-prompt-file", promptFile(), "--allowedTools"]
        argv += Self.readOnlyRules + toolRules(tools) + allow
        argv += started ? ["--resume", sessionId] : ["--session-id", sessionId]
        doing = ""
        stoppedByUser = false
        chatStarted = Date()
        let timeout: TimeInterval? = config.bool("chatCompact") ? config.double("chatTimeoutSeconds") : nil
        chatHandle = ProcessRunner.run(claude, argv, cwd: config.clawdHome, stdin: ctx + "\n\n" + text, timeout: timeout,
                                       onLine: { [weak self] line in self?.streamLine(line) }) { [weak self] r in
            self?.chatDone(r)
        }
        if chatHandle == nil { add("note", T("chat.error", "could not start claude")) }
        onChange?()
    }

    /// What Clawd is busy with, from the stream: "Reading x", "Running: ls ...".
    func streamLine(_ line: String) {
        if line.hasPrefix("{\"type\":\"user\"") { DispatchQueue.main.async { self.doing = ""; self.onChange?() }; return }
        guard line.hasPrefix("{\"type\":\"assistant\""), let d = line.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let content = (j["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
        var latest: String?
        for b in content { if let s = Self.doingText(b) { latest = s } }
        if let latest { DispatchQueue.main.async { self.doing = latest; self.onChange?() } }
    }

    public static func doingText(_ b: [String: Any]) -> String? {
        func cut(_ s: Any?) -> String {
            let t = ("\(s ?? "")".components(separatedBy: .newlines).first ?? "").trimmingCharacters(in: .whitespaces)
            return t.count > 44 ? String(t.prefix(44)).trimmingCharacters(in: .whitespaces) : t
        }
        switch b["type"] as? String {
        case "thinking": return T("chat.doing.think")
        case "text": return T("chat.doing.write")
        case "tool_use": break
        default: return nil
        }
        let input = b["input"] as? [String: Any] ?? [:]
        let name = b["name"] as? String ?? ""
        switch name {
        case "Read": return T("chat.doing.read", cut(((input["file_path"] as? String) ?? "" as String).components(separatedBy: "/").last))
        case "Glob", "Grep": return T("chat.doing.search", cut(input["pattern"]))
        case "Bash", "PowerShell": return T("chat.doing.run", cut(input["command"]))
        case "WebFetch": return URL(string: input["url"] as? String ?? "")?.host.map { T("chat.doing.fetch", $0) } ?? T("chat.doing.web")
        case "WebSearch": return T("chat.doing.websearch", cut(input["query"]))
        case "Task", "Agent": return T("chat.doing.agent")
        default:
            if let r = name.range(of: #"^mcp__(.+?)__(.+)$"#, options: .regularExpression) {
                let parts = String(name[r]).dropFirst(5).components(separatedBy: "__")
                return T("chat.doing.tool", "\(parts.first ?? ""): \(parts.dropFirst().joined(separator: "__"))")
            }
            return T("chat.doing.tool", name)
        }
    }

    public func stop() {
        guard let h = chatHandle else { return }
        stoppedByUser = true
        h.cancel()
    }

    /// The stream's last word: the `result` line, the same object `--output-format json` gives.
    static func resultLine(_ out: String) -> [String: Any]? {
        for line in out.components(separatedBy: "\n").reversed() where line.contains("\"type\":\"result\"") {
            if let d = line.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return j }
        }
        return nil
    }

    func chatDone(_ r: ProcessResult) {
        chatHandle = nil
        doing = ""
        if stoppedByUser { add("note", T("chat.stopped")); onChange?(); return }
        if r.timedOut { add("note", T("chat.timeout", config.int("chatTimeoutSeconds"))); onChange?(); return }
        let j = Self.resultLine(r.stdout)
        if let j, (j["is_error"] as? Bool) != true, let result = j["result"] as? String {
            started = true
            let rep = readReply(result)
            // Actions refused for want of permission: a card for the user to approve.
            let calls: [ChatMessage.Call] = (j["permission_denials"] as? [[String: Any]] ?? []).compactMap { d in
                guard let tool = d["tool_name"] as? String, tool.hasPrefix("mcp__") else { return nil }
                let input = (try? JSONSerialization.data(withJSONObject: d["tool_input"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                return .init(tool: tool, input: input)
            }
            var msg: ChatMessage?
            if !rep.text.isEmpty || rep.run != nil || !calls.isEmpty { msg = add("clawd", rep.text, run: rep.run) }
            if !calls.isEmpty, let msg { msg.act = .init(state: "pending", calls: calls); save() }
            for n in rep.notes { add("note", n) }
            addGrantCards(rep)
            if let msg, msg.run != nil, config.bool("chatAutoRun") {
                if autoChain < Self.autoChainMax { autoChain += 1; startRun(msg) }
                else { add("note", T("chat.autoStop", Self.autoChainMax)) }
            }
        } else {
            var why = (j?["result"] as? String) ?? ""
            if why.isEmpty { why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
            if why.isEmpty { why = "exit \(r.status)" }
            if why.count > 300 { why = String(why.prefix(300)) + "…" }
            add("note", T("chat.error", why))
        }
        if !panelVisible() { unread = true; mascotAct?("wave") }
        onChange?()
    }

    // MARK: - approved scripts (zsh)

    public func startRun(_ msg: ChatMessage) {
        guard runHandle == nil, chatHandle == nil, let run = msg.run, run.state == "pending" else { return }
        msg.run?.state = "running"
        save()
        runHandle = ProcessRunner.run("/bin/zsh", ["-c", run.script], cwd: config.clawdHome, timeout: 1800) { [weak self] r in
            guard let self else { return }
            self.runHandle = nil
            msg.run?.state = "done"; msg.run?.code = r.status
            self.save()
            var text = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 3000 { text = "…" + String(text.suffix(3000)) }
            // Claude sums up what happened; the sizes in the tips are stale now.
            self.send("[run result] exit code \(r.status)\n\(text)", hidden: true)
            self.advisor.start()
            self.onChange?()
        }
        onChange?()
    }

    public func setRunState(_ msg: ChatMessage, _ state: String) {
        guard msg.run?.state == "pending" else { return }
        msg.run?.state = state; save(); onChange?()
    }

    /// Refine: the user's words go to Clawd together with the script; the old one is replaced.
    public func refineRun(_ msg: ChatMessage, _ words: String) {
        guard msg.run?.state == "pending" else { return }
        msg.run?.state = "replaced"
        save()
        send("\(words)\n\n(about the script you proposed:\n\(msg.run?.script ?? "")\n)")
    }

    /// Clawd asked to act with a tool and was refused: on Run the same conversation goes on with exactly those tools.
    public func approveAct(_ msg: ChatMessage) {
        guard chatHandle == nil, let act = msg.act, act.state == "pending" else { return }
        msg.act?.state = "approved"
        save()
        let list = act.calls.map { "- \($0.tool) \($0.input)" }.joined(separator: "\n")
        send("[approved] The user clicked Run: make exactly these calls now, then say briefly what came of them.\n\(list)",
             hidden: true, allow: Array(Set(act.calls.map(\.tool))).sorted())
    }

    public func setActState(_ msg: ChatMessage, _ state: String) {
        guard msg.act?.state == "pending" else { return }
        msg.act?.state = state; save(); onChange?()
    }

    // MARK: - reminders tick

    public func fireReminders() {
        let now = Date()
        for (r, to) in reminders.fireDue(now: now) {
            var text = r.text
            if now.timeIntervalSince(r.at) > 300 { text = T("chat.remindLate", text, ReminderStore.formatTime(r.at)) }
            add("remind", text)
            onReminderFired?(r, to, text)
            mascotAct?("jump")
        }
    }

    // MARK: - phone conversation (Remote Control)

    public var clawdSessionId: String {
        (JSONFile.readObject(config.dataFile("clawd-state.json"))?["sessionId"] as? String) ?? ""
    }

    public static func projectKey(_ dir: URL) -> String {
        dir.path.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    }

    public func transcriptPath(_ id: String) -> URL {
        Paths.claudeConfigDir.appendingPathComponent("projects/\(Self.projectKey(config.clawdHome))/\(id).jsonl")
    }

    /// Reads what was added to Clawd's own session transcript since the last look.
    public func updateRemoteFeed() {
        let id = clawdSessionId
        guard !id.isEmpty else { return }
        let path = transcriptPath(id).path
        if path != remotePath { remotePath = path; remoteOffset = 0; remoteItems = [] }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path), let len = attrs[.size] as? UInt64 else { return }
        if len < remoteOffset { remoteOffset = 0; remoteItems = [] }
        guard len > remoteOffset, let h = FileHandle(forReadingAtPath: path) else { return }
        try? h.seek(toOffset: remoteOffset)
        let data = (try? h.readToEnd()) ?? Data()
        try? h.close()
        guard let end = data.lastIndex(of: 0x0A) else { return }
        remoteOffset += UInt64(end - data.startIndex + 1)
        var changed = false
        for lineSub in data[data.startIndex..<end].split(separator: 0x0A) {
            let line = String(decoding: lineSub, as: UTF8.self)
            guard line.range(of: #""type":"(user|assistant)""#, options: .regularExpression) != nil,
                  !line.contains("\"tool_result\""), !line.contains("\"isMeta\":true"),
                  let j = (try? JSONSerialization.jsonObject(with: Data(lineSub))) as? [String: Any],
                  let type = j["type"] as? String, ["user", "assistant"].contains(type), (j["isSidechain"] as? Bool) != true else { continue }
            let c = (j["message"] as? [String: Any])?["content"]
            var say = ""
            if let s = c as? String { say = s }
            else if let arr = c as? [[String: Any]] { say = arr.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n") }
            say = Self.plain(say)
            // Commands, caveats and reminders injected by Claude Code are not words.
            if say.isEmpty || say.hasPrefix("<") { continue }
            let at = (j["timestamp"] as? String).flatMap(ISO8601.parse) ?? Date.distantPast
            let role = type == "user" ? "user" : "clawd"
            if role == "clawd", let last = remoteItems.last, last.role == "clawd" { last.text += "\n\n\(say)"; changed = true; continue }
            if at < since { continue }
            let m = ChatMessage(role: role, text: say, at: at); m.remote = true
            remoteItems.append(m)
            changed = true
        }
        if remoteItems.count > 40 { remoteItems.removeFirst(remoteItems.count - 40) }
        if changed { onChange?() }
    }

    // MARK: - tasks

    public var tasksDir: URL { config.clawdHome.appendingPathComponent("tasks") }

    public func tasks() -> [ClawdTask] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { f in
            guard let raw = try? String(contentsOf: f, encoding: .utf8) else { return nil }
            return ClawdTask.parse(raw, name: f.deletingPathExtension().lastPathComponent, path: f)
        }
    }

    public func findTask(_ name: String) -> ClawdTask? { tasks().first { $0.name == name } }

    @discardableResult
    public func writeTask(_ name: String, _ head: [String: String], _ prompt: String) -> URL? {
        try? FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        let file = ListStore.clean(name)
        guard !file.isEmpty else { return nil }
        var lines = ["---"]
        for k in ["every", "at", "tools", "model", "hours", "limit", "paused"] { if let v = head[k], !v.isEmpty { lines.append("\(k): \(v)") } }
        lines += ["---", prompt.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        let path = tasksDir.appendingPathComponent("\(file).md")
        do { try lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8) } catch { return nil }
        return path
    }

    @discardableResult
    public func removeTask(_ name: String) -> ClawdTask? {
        guard let t = findTask(name) else { return nil }
        guard (try? FileManager.default.removeItem(at: t.path)) != nil else { return nil }
        var st = taskState(); st[t.name] = nil; saveTaskState(st)
        onChange?()
        return t
    }

    public func setPaused(_ t: ClawdTask, _ paused: Bool) {
        guard var raw = try? String(contentsOf: t.path, encoding: .utf8) else { return }
        raw = raw.replacingOccurrences(of: #"(?m)^\s*paused\s*:.*\r?\n"#, with: "", options: .regularExpression)
        if paused { raw = raw.replacingOccurrences(of: #"^(\s*---\s*\r?\n)"#, with: "$1paused: yes\n", options: .regularExpression) }
        try? raw.write(to: t.path, atomically: true, encoding: .utf8)
        onChange?()
    }

    public struct TaskRun: Codable { public var at: Date; public var text: String; public var told: Bool }
    public struct TaskStateEntry: Codable {
        public var last: Date?
        public var report: String = ""
        public var error: String = ""
        public var asked: String = ""
        public var history: [TaskRun] = []
    }

    public func taskState() -> [String: TaskStateEntry] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: tasksStatePath) else { return [:] }
        return (try? dec.decode([String: TaskStateEntry].self, from: d)) ?? [:]
    }

    func saveTaskState(_ st: [String: TaskStateEntry]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(st) { try? d.write(to: tasksStatePath, options: .atomic) }
    }

    /// Tasks wait while the plan's usage is high; nil - may run, otherwise the percent it waits on.
    public func budgetWait(_ t: ClawdTask) -> Int? {
        let max = t.limit ?? config.int("tasksMaxPercent")
        guard max > 0, max < 100, let u = usage() else { return nil }
        let pct = Swift.max(u.session ?? 0, u.week ?? 0)
        return pct >= max ? pct : nil
    }

    public func isQueued(_ name: String) -> Bool { taskQueue.contains(name) }

    /// "Run now": at once if nothing runs, otherwise after the running one.
    public func requestRun(_ t: ClawdTask) {
        if taskHandle != nil {
            if runningTask != t.name && !taskQueue.contains(t.name) { taskQueue.append(t.name) }
            onChange?()
            return
        }
        startTask(t)
    }

    func startTask(_ t: ClawdTask, model: String = "", retry: Bool = false) {
        guard taskHandle == nil, !t.prompt.isEmpty, let claude = claude() else { return }
        let prev = taskState()[t.name]
        let when = t.at != nil ? "at=\"\(t.atText)\"" : "every=\"\(t.everyText)\""
        var head = ["<task name=\"\(t.name)\" \(when)>"]
        if let last = prev?.last {
            let lf = DateFormatter(); lf.dateFormat = "yyyy-MM-dd HH:mm"
            let uf = ISO8601DateFormatter()
            head.append("last run: \(lf.string(from: last)) local time = \(uf.string(from: last))")
        } else {
            head.append("last run: never - this is the first one")
        }
        let runs = (prev?.history ?? []).suffix(5)
        if !runs.isEmpty {
            let rf = DateFormatter(); rf.dateFormat = "MM-dd HH:mm"
            head.append("recent runs, oldest first (\"told\" - the user was told):")
            for h in runs { head.append("- \(rf.string(from: h.at))\(h.told ? " told" : ""): \(h.text)") }
        }
        if let rep = prev?.report, !rep.isEmpty { head.append("your last message to the user:\n\(rep)") }
        head.append("</task>")
        let text = context() + "\n\n" + head.joined(separator: "\n") + "\n\n" + t.prompt + "\n\n" +
            "(Answer in the fields: tell = false unless the user needs to know or do something now; " +
            "message - only when tell is true; summary - always, one short line.)"
        let m = model.isEmpty ? (t.model.isEmpty ? config.string("quickModel") : t.model) : model
        var argv = ["-p", "--output-format", "json", "--model", m, "--json-schema", Self.taskSchema,
                    "--permission-mode", "default", "--no-session-persistence",
                    "--disallowedTools", "Write", "Edit", "NotebookEdit",
                    "--append-system-prompt-file", Paths.resource("prompts/tasks-prompt.md").path]
        if !t.tools.contains(where: { $0.hasPrefix("mcp__") }) { argv.append("--strict-mcp-config") }
        argv += ["--allowedTools"] + Self.readOnlyRules + t.tools
        runningTask = t.name
        taskHandle = ProcessRunner.run(claude, argv, cwd: config.clawdHome, stdin: text, timeout: config.double("chatTimeoutSeconds")) { [weak self] r in
            self?.taskDone(t, r, retry: retry)
        }
        if taskHandle == nil { runningTask = nil; setTaskResult(t, report: nil, why: "could not start claude") }
        onChange?()
    }

    /// What a refused call would need as a permission rule: a command by its first words, a page by its site.
    public static func deniedRule(_ d: [String: Any]) -> String? {
        let tool = d["tool_name"] as? String ?? ""
        let input = d["tool_input"] as? [String: Any] ?? [:]
        if ["Bash", "PowerShell"].contains(tool), let cmd = input["command"] as? String {
            var words: [String] = []
            for w in cmd.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init) {
                if words.count >= 3 || w.hasPrefix("-") || w.range(of: #"[\\/:"'$|;&<>(){}=]"#, options: .regularExpression) != nil { break }
                words.append(w)
            }
            return words.isEmpty ? nil : "\(tool)(\(words.joined(separator: " ")):*)"
        }
        if tool == "WebFetch" { return URL(string: input["url"] as? String ?? "")?.host.map { "WebFetch(domain:\($0))" } ?? "WebFetch" }
        if ["Write", "Edit", "NotebookEdit"].contains(tool) { return nil }   // tasks never write
        return tool.isEmpty ? nil : tool
    }

    func taskDone(_ t: ClawdTask, _ r: ProcessResult, retry: Bool) {
        taskHandle = nil
        runningTask = nil
        if r.timedOut { setTaskResult(t, report: nil, why: T("task.timeout", config.int("chatTimeoutSeconds"))); return }
        let j = r.stdout.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        if let j, (j["is_error"] as? Bool) != true, j["result"] != nil {
            let need = (j["permission_denials"] as? [[String: Any]] ?? []).compactMap(Self.deniedRule)
            if let so = j["structured_output"] as? [String: Any] {
                let said = (so["tell"] as? Bool) == true ? (so["message"] as? String ?? "") : ""
                setTaskResult(t, report: said, why: "", need: need, summary: so["summary"] as? String ?? "")
                return
            }
            let result = (j["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isEmpty && need.isEmpty {
                // A small model sometimes stops after its tool calls without a word: one more go with the chat's model.
                if !retry { startTask(t, model: config.string("chatModel"), retry: true) }
                if taskHandle == nil { setTaskResult(t, report: nil, why: T("task.empty")) }
            } else {
                setTaskResult(t, report: result, why: "", need: need)
            }
        } else {
            var why = (j?["result"] as? String) ?? ""
            if why.isEmpty { why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
            if why.isEmpty { why = "exit \(r.status)" }
            if why.count > 300 { why = String(why.prefix(300)) + "…" }
            setTaskResult(t, report: nil, why: why)
        }
    }

    func setTaskResult(_ t: ClawdTask, report: String?, why: String, need: [String] = [], summary: String = "") {
        var st = taskState()
        var e = st[t.name] ?? TaskStateEntry()
        e.last = Date()
        guard let report else {
            // The same failure every ten minutes is said once.
            if why != e.error { add("note", T("task.error", t.name, why)) }
            e.error = why
            st[t.name] = e; saveTaskState(st); onChange?()
            return
        }
        e.error = ""
        let said = report.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNothing = said.range(of: #"^\W*NOTHING\W*$"#, options: .regularExpression) != nil
        var sum = summary.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if sum.count > 200 { sum = String(sum.prefix(200)) + "…" }
        let told = !said.isEmpty && !isNothing
        if !sum.isEmpty || told {
            var line = sum.isEmpty ? said.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) : sum
            if line.count > 200 { line = String(line.prefix(200)) + "…" }
            e.history = Array((e.history + [TaskRun(at: Date(), text: line, told: told)]).suffix(Self.historyKeep))
        }
        // Refused permissions: a card to allow them, asked once for the same set.
        let needed = Array(Set(need.filter { ClawdTask.isToolRule($0) && !t.tools.contains($0) })).sorted()
        let key = needed.joined(separator: " ")
        if !needed.isEmpty && key != e.asked {
            e.asked = key
            st[t.name] = e; saveTaskState(st)
            let msg = add("clawd", "[\(t.name)] " + (told ? said : T("task.needs")))
            msg.task = t.name
            msg.grant = .init(task: t.name, rules: needed, state: "pending")
            save()
            if !panelVisible() { unread = true; notify?("Clawd · \(t.name)", T("task.needs")) }
            onChange?()
            return
        }
        // A sentence and then NOTHING on its own line is quiet too, unless it carries blocks.
        if said.isEmpty || isNothing || (said.range(of: #"(?:^|\n)\W*NOTHING\W*$"#, options: .regularExpression) != nil && !said.contains("```")) {
            st[t.name] = e; saveTaskState(st); onChange?(); return
        }
        let rep = readReply(said, fromTask: true)
        e.report = rep.text.count > 1500 ? String(rep.text.prefix(1500)) + "…" : rep.text
        st[t.name] = e; saveTaskState(st)
        let msg = add("clawd", "[\(t.name)] \(rep.text)", run: rep.run)
        msg.task = t.name
        save()
        for n in rep.notes { add("note", n) }
        if !panelVisible() {
            unread = true
            notify?("Clawd · \(t.name)", rep.text.count > 200 ? String(rep.text.prefix(200)) + "…" : rep.text)
            mascotAct?("wave")
        }
        onChange?()
    }

    /// "Allow" on the card: the rules go to the task's `tools`, and it runs again now.
    public func grant(_ msg: ChatMessage) {
        guard let g = msg.grant, g.state == "pending" else { return }
        guard let t = findTask(g.task) else { msg.grant?.state = "gone"; save(); onChange?(); return }
        let all = t.tools + g.rules.filter { !t.tools.contains($0) }
        guard var raw = try? String(contentsOf: t.path, encoding: .utf8) else { return }
        let line = "tools: \(all.joined(separator: " "))"
        let esc = NSRegularExpression.escapedTemplate(for: line)
        if raw.range(of: #"(?m)^\s*tools\s*:"#, options: .regularExpression) != nil {
            raw = raw.replacingOccurrences(of: #"(?m)^\s*tools\s*:.*$"#, with: esc, options: .regularExpression)
        } else {
            raw = raw.replacingOccurrences(of: #"^(\s*---\s*\r?\n)"#, with: "$1" + esc + "\n", options: .regularExpression)
        }
        do { try raw.write(to: t.path, atomically: true, encoding: .utf8) } catch { add("note", T("chat.error", "\(error)")); return }
        msg.grant?.state = "granted"
        save()
        var st = taskState()
        if var e = st[t.name] { e.last = nil; e.asked = ""; st[t.name] = e; saveTaskState(st) }
        onChange?()
    }

    public func setGrantState(_ msg: ChatMessage, _ state: String) {
        guard msg.grant?.state == "pending" else { return }
        msg.grant?.state = state; save(); onChange?()
    }

    /// Every main tick: start the next due task - one at a time.
    public func updateTasks() {
        guard config.bool("showTasks"), taskHandle == nil else { return }
        while !taskQueue.isEmpty {
            let name = taskQueue.removeFirst()
            if let t = findTask(name) { startTask(t); if taskHandle != nil { return } }
        }
        let st = taskState()
        let now = Date()
        for t in tasks() {
            if t.paused || (t.at == nil && t.every == nil) { continue }
            if budgetWait(t) != nil { continue }
            let last = st[t.name]?.last ?? .distantPast
            if t.at != nil {
                // Once per time of day; a time missed while the Mac was off - once, when it is on.
                // A new task waits for its next time instead of going off for yesterday's.
                var sinceT = last
                if let made = (try? FileManager.default.attributesOfItem(atPath: t.path.path))?[.creationDate] as? Date, made > sinceT { sinceT = made }
                if let s = t.slot(now), s > sinceT { startTask(t); return }
                continue
            }
            if !t.inHours(now) { continue }
            if let e = t.every, now.timeIntervalSince(last) >= e { startTask(t); return }
        }
    }
}
