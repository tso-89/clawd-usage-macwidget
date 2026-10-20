import Foundation

/// `claude -p /usage` parsed: the same numbers as /usage inside Claude Code. No model call, no tokens.
public struct UsagePeriod: Equatable {
    public var requests: Int
    public var sessions: Int
    public var lines: [String]
    public init(requests: Int, sessions: Int, lines: [String]) { self.requests = requests; self.sessions = sessions; self.lines = lines }
}

public struct Usage: Equatable {
    public var session: Int?
    public var week: Int?
    public var fable: Int?
    public var sessionReset: Date?
    public var weekReset: Date?
    public var fableReset: Date?
    public var day: UsagePeriod?
    public var week7: UsagePeriod?
    public init() {}
}

public enum UsageParser {
    // "resets Oct 17, 5:19am (Europe/Moscow)" and, since Claude Code 2.1.30x, "resets Oct 18 at 12:50am (...)".
    static let stampRe = try! NSRegularExpression(pattern: #"([A-Za-z]{3})\s+(\d{1,2})(?:,|\s+at)\s*(\d{1,2})(?::(\d{2}))?\s*([ap]m)"#, options: [.caseInsensitive])

    /// Reset stamp in local time. No year in the text: this year, or the next one when that
    /// lands more than a month in the past (New Year's Eve).
    public static func parseResetStamp(_ s: String, now: Date = Date()) -> Date? {
        let ns = s as NSString
        guard let m = stampRe.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? { let r = m.range(at: i); return r.location == NSNotFound ? nil : ns.substring(with: r) }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let mon = months.firstIndex(of: (g(1) ?? "").lowercased()), let day = Int(g(2) ?? ""),
              var hour = Int(g(3) ?? "") else { return nil }
        let minute = Int(g(4) ?? "0") ?? 0
        let pm = (g(5) ?? "").lowercased() == "pm"
        if hour == 12 { hour = 0 }
        if pm { hour += 12 }
        let cal = Calendar.current
        var dc = DateComponents()
        dc.year = cal.component(.year, from: now); dc.month = mon + 1; dc.day = day; dc.hour = hour; dc.minute = minute
        guard var d = cal.date(from: dc) else { return nil }
        if d < now.addingTimeInterval(-30 * 86400) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
        return d
    }

    static func limit(_ text: String, _ label: String, now: Date) -> (Int, Date?)? {
        let re = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: label) + #":\s*(\d+)%(?:[^\r\n]*?resets\s*([^\r\n]+))?"#)
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let pct = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let r = m.range(at: 2)
        let reset = r.location == NSNotFound ? nil : parseResetStamp(ns.substring(with: r), now: now)
        return (pct, reset)
    }

    /// "Last 24h · 298 requests · 12 sessions" and the indented lines below it ("1 request" on a quiet day).
    public static func parsePeriod(_ text: String, _ label: String) -> UsagePeriod? {
        let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: label) +
            #"[^\r\n]*?(\d+)\s+requests?\b[^\r\n]*?(\d+)\s+sessions?\b[^\r\n]*\r?\n((?:[ \t]+[^\r\n]*\r?\n?)*)"#
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let lines = ns.substring(with: m.range(at: 3)).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return UsagePeriod(requests: Int(ns.substring(with: m.range(at: 1))) ?? 0,
                           sessions: Int(ns.substring(with: m.range(at: 2))) ?? 0, lines: lines)
    }

    /// nil when neither the session nor the week line is there (an error, a login prompt...).
    public static func parse(_ text: String, now: Date = Date()) -> Usage? {
        var u = Usage()
        // No "resets" means the window has not started: that is 0%, not "no data".
        if let (p, r) = limit(text, "Current session", now: now) { u.session = p; u.sessionReset = r }
        if let (p, r) = limit(text, "Current week (all models)", now: now) { u.week = p; u.weekReset = r }
        if let (p, r) = limit(text, "Current week (Fable)", now: now) { u.fable = p; u.fableReset = r }
        u.day = parsePeriod(text, "Last 24h")
        u.week7 = parsePeriod(text, "Last 7d")
        return (u.session != nil || u.week != nil) ? u : nil
    }

    // Stats lines are shortened; unknown ones are kept as is, so new metrics are not lost.
    static let statRules: [(String, String)] = [
        (#"^(\d+)% of your usage was at >(\S+) context"#, "stat.bigCtx"),
        (#"^(\d+)% of your usage went to always-on context over (\S+)"#, "stat.alwaysOn"),
        (#"^(\d+)% of your usage came from subagent-heavy"#, "stat.subagents"),
        (#"^(\d+)% of your usage came from sessions active for (\d+)\+? hours"#, "stat.long"),
        (#"^(\d+)% of your usage was while (\d+)\+? sessions ran in parallel"#, "stat.parallel"),
        (#"^Top MCP servers:\s*(.+)$"#, "stat.mcp"),
        (#"^Top skills:\s*(.+)$"#, "stat.skills"),
        (#"^Top subagents:\s*(.+)$"#, "stat.agents"),
    ]

    public static func formatStatLine(_ line: String) -> String {
        let ns = line as NSString
        for (pat, key) in statRules {
            guard I18n.has(key), let re = try? NSRegularExpression(pattern: pat),
                  let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            var args: [Any] = []
            for i in 1..<m.numberOfRanges { args.append(ns.substring(with: m.range(at: i))) }
            return TD(key, default: line, args)
        }
        return line
    }
}

/// Runs the probe asynchronously and keeps the last good answer.
public final class UsageProbe {
    public private(set) var usage: Usage?
    public private(set) var at: Date?
    public private(set) var tried = Date.distantPast
    private var handle: ProcessRunner.Handle?
    public var running: Bool { handle != nil }
    public var onSample: ((Usage) -> Void)?

    public init() {}

    public func start(claude: String) {
        guard handle == nil else { return }
        tried = Date()
        handle = ProcessRunner.run(claude, ["-p", "/usage", "--output-format", "text", "--no-session-persistence"],
                                   cwd: Paths.dataDir, timeout: 60) { [weak self] r in
            guard let self else { return }
            self.handle = nil
            if let u = UsageParser.parse(r.stdout) {
                self.usage = u
                self.at = Date()
                self.onSample?(u)
            } else if !r.stdout.isEmpty || !r.stderr.isEmpty {
                ErrorLog.write("usage", String((r.stderr + r.stdout).prefix(300)))
            }
        }
    }

    /// For the developer/recorder tooling and tests.
    public func inject(_ u: Usage) { usage = u; at = Date() }
}
