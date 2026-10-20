import Foundation

/// Reminders are plain files in Clawd's home, so anyone can make one: the chat, Clawd's own
/// session, or the user by hand (upstream lib/reminders.ps1):
///   reminders/2026-11/2026-11-16 10-00 Pay the taxes.md
///   ---
///   at: 2026-11-16T10:00
///   repeat: monthly
///   ---
///   Pay the taxes
public struct Reminder: Equatable {
    public var path: URL
    public var rel: String
    public var at: Date
    public var text: String
    public var repeatRule: String
    public init(path: URL, rel: String, at: Date, text: String, repeatRule: String) {
        self.path = path; self.rel = rel; self.at = at; self.text = text; self.repeatRule = repeatRule
    }
}

public final class ReminderStore {
    public static let repeats = ["daily", "weekly", "monthly", "yearly"]
    public var home: () -> URL
    private var fired = Set<String>()

    public init(home: @escaping () -> URL) { self.home = home }

    public var dir: URL { home().appendingPathComponent("reminders") }

    static let localFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; return f
    }()

    public static func parseAt(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return ISO8601.parse(s)
    }

    /// Active reminders, soonest first.
    public func all() -> [Reminder] {
        // Resolved, so /var and /private/var (and other symlinked homes) compare equal.
        let root = dir.resolvingSymlinksInPath()
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var list: [Reminder] = []
        for case let found as URL in en where found.pathExtension == "md" {
            let f = found.resolvingSymlinksInPath()
            guard f.path.hasPrefix(root.path + "/") else { continue }
            let rel = String(f.path.dropFirst(root.path.count + 1))
            if rel.hasPrefix("done/") || fired.contains(f.path) { continue }
            guard let raw = try? String(contentsOf: f, encoding: .utf8) else { continue }
            var at: Date?, text = "", rep = ""
            if let fm = Self.frontMatter(raw) {
                if let a = fm.head.firstMatch(#"(?m)^\s*at:\s*(\S+)"#) { at = Self.parseAt(a) }
                if let r = fm.head.firstMatch(#"(?m)^\s*repeat:\s*(\w+)"#), Self.repeats.contains(r.lowercased()) { rep = r.lowercased() }
                text = fm.body.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let base = f.deletingPathExtension().lastPathComponent
            let n = Self.nameParts(base)
            if at == nil, let n { at = n.at }
            guard let at else { continue }
            if text.isEmpty { text = n?.text ?? base }
            list.append(Reminder(path: f, rel: rel, at: at, text: text, repeatRule: rep))
        }
        return list.sorted { $0.at < $1.at }
    }

    /// "2026-11-16 10-00 Pay the taxes" -> date and text.
    static func nameParts(_ base: String) -> (at: Date, text: String)? {
        guard let re = try? NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2})[ T](\d{2})-(\d{2})\s*(.*)$"#) else { return nil }
        let ns = base as NSString
        guard let m = re.firstMatch(in: base, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let s = "\(ns.substring(with: m.range(at: 1)))T\(ns.substring(with: m.range(at: 2))):\(ns.substring(with: m.range(at: 3)))"
        guard let d = localFmt.date(from: s) else { return nil }
        return (d, ns.substring(with: m.range(at: 4)))
    }

    public static func frontMatter(_ raw: String) -> (head: String, body: String)? {
        guard let re = try? NSRegularExpression(pattern: #"(?s)^\s*---\s*\r?\n(.*?)\r?\n---\s*\r?\n?(.*)$"#) else { return nil }
        let ns = raw as NSString
        guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
    }

    @discardableResult
    public func create(at: Date, text: String, repeatRule: String = "") -> URL? {
        let ym = DateFormatter(); ym.locale = Locale(identifier: "en_US_POSIX"); ym.dateFormat = "yyyy-MM"
        let d = dir.appendingPathComponent(ym.string(from: at))
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var title = text.replacingOccurrences(of: #"[\\/:*?"<>|\r\n]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if title.count > 50 { title = String(title.prefix(50)).trimmingCharacters(in: .whitespaces) }
        let nf = DateFormatter(); nf.locale = Locale(identifier: "en_US_POSIX"); nf.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "\(nf.string(from: at)) \(title)"
        var path = d.appendingPathComponent("\(base).md")
        var i = 2
        while FileManager.default.fileExists(atPath: path.path) { path = d.appendingPathComponent("\(base) (\(i)).md"); i += 1 }
        let rep = Self.repeats.contains(repeatRule) ? "repeat: \(repeatRule)\n" : ""
        let body = "---\nat: \(Self.localFmt.string(from: at))\n\(rep)---\n\(text)\n"
        do { try body.write(to: path, atomically: true, encoding: .utf8) } catch { return nil }
        return path
    }

    /// By path relative to the reminders folder, or just by file name.
    @discardableResult
    public func remove(_ name: String) -> Reminder? {
        let n = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        for r in all() where r.rel == n || r.path.lastPathComponent == n || r.path.deletingPathExtension().lastPathComponent == n {
            if (try? FileManager.default.removeItem(at: r.path)) != nil { return r }
        }
        return nil
    }

    /// Moving one is a new file for the new time; a repeating one keeps repeating from there.
    @discardableResult
    public func move(_ r: Reminder, to at: Date, text: String? = nil) -> URL? {
        try? FileManager.default.removeItem(at: r.path)
        return create(at: at, text: text ?? r.text, repeatRule: r.repeatRule)
    }

    /// The first time after `after`: the series goes on from `at` (the widget may have been off).
    public static func next(_ at: Date, rule: String, after: Date) -> Date? {
        let cal = Calendar.current
        for k in 1..<100_000 {
            let n: Date?
            switch rule {
            case "daily": n = cal.date(byAdding: .day, value: k, to: at)
            case "weekly": n = cal.date(byAdding: .day, value: 7 * k, to: at)
            case "monthly": n = cal.date(byAdding: .month, value: k, to: at)
            case "yearly": n = cal.date(byAdding: .year, value: k, to: at)
            default: return nil
            }
            if let n, n > after { return n }
        }
        return nil
    }

    /// Fires what is due: moves it to done/ (and writes the next one for a repeating reminder).
    /// Returns (reminder, path in done/) for each one fired.
    public func fireDue(now: Date = Date()) -> [(Reminder, URL?)] {
        var out: [(Reminder, URL?)] = []
        let ym = DateFormatter(); ym.locale = Locale(identifier: "en_US_POSIX"); ym.dateFormat = "yyyy-MM"
        for r in all() {
            if r.at > now { break }
            fired.insert(r.path.path)
            let doneDir = dir.resolvingSymlinksInPath().appendingPathComponent("done").appendingPathComponent(ym.string(from: r.at))
            try? FileManager.default.createDirectory(at: doneDir, withIntermediateDirectories: true)
            let to = doneDir.appendingPathComponent(r.path.lastPathComponent)
            try? FileManager.default.removeItem(at: to)
            let moved = (try? FileManager.default.moveItem(at: r.path, to: to)) != nil
            if !r.repeatRule.isEmpty, let n = Self.next(r.at, rule: r.repeatRule, after: now) {
                create(at: n, text: r.text, repeatRule: r.repeatRule)
            }
            out.append((r, moved ? to : nil))
        }
        return out
    }

    /// Recently fired ones, newest first.
    public func done(count: Int = 5) -> [(at: Date, text: String)] {
        let d = dir.appendingPathComponent("done")
        guard let en = FileManager.default.enumerator(at: d, includingPropertiesForKeys: nil) else { return [] }
        let files = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(count)
        return files.compactMap { f in
            guard let n = Self.nameParts(f.deletingPathExtension().lastPathComponent) else { return nil }
            var text = n.text
            if let raw = try? String(contentsOf: f, encoding: .utf8), let fm = Self.frontMatter(raw) {
                let b = fm.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !b.isEmpty { text = b }
            }
            return (n.at, text)
        }
    }

    public static func formatTime(_ at: Date, now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = I18n.locale
        f.dateFormat = Calendar.current.isDate(at, inSameDayAs: now) ? "HH:mm" : "EEE d MMM HH:mm"
        return f.string(from: at)
    }
}

/// "When" as people write it: 18:30, tomorrow 10:00, +20m, in 2 hours, mon 9:00, через неделю 15:00,
/// demain 18h30, 19.10 14:00, 19.10.2026, 2026-10-19 14:00. A day without a time is 10:00; a time
/// already gone today is tomorrow. nil - not understood (then the quick model is asked).
public enum WhenParser {
    enum Unit { case half, min, hour, day, week, month }

    static func offset(_ s: String) -> (n: Int, unit: Unit)? {
        let pat = #"^(\+|через |in |dans )?\s*(\d+|an?|une?)?\s*(m|min|mins|minutes?|м|мин\w*|полчаса|h|hours?|heures?|ч|час\w*|d|days?|jours?|д|дн\w*|день|w|weeks?|semaines?|н|нед\w*|mo|months?|mois|мес\w*)$"#
        guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String { let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r) }
        let num = g(2)
        let n: Int
        if let v = Int(num) { n = v }
        else if ["через", "in", "dans"].contains(g(1).trimmingCharacters(in: .whitespaces)) { n = 1 }
        else { return nil }
        let u = g(3)
        let unit: Unit
        if u == "полчаса" { unit = .half }
        else if u.hasPrefix("mo") || u.hasPrefix("мес") { unit = .month }
        else if u.hasPrefix("w") || u.hasPrefix("н") || u.hasPrefix("sem") { unit = .week }
        else if u.hasPrefix("m") || u.hasPrefix("м") { unit = .min }
        else if u.hasPrefix("h") || u.hasPrefix("ч") { unit = .hour }
        else { unit = .day }
        return (n, unit)
    }

    public static func parse(_ input: String, now: Date = Date()) -> Date? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !s.isEmpty else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func at(_ day: Date, _ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day }

        if let o = offset(s) {
            switch o.unit {
            case .half: return now.addingTimeInterval(Double(30 * o.n) * 60)
            case .min: return now.addingTimeInterval(Double(o.n) * 60)
            case .hour: return now.addingTimeInterval(Double(o.n) * 3600)
            default: break
            }
        }
        // Optional time at the end: "... 9", "... 9:30", "... 9.30", "... 9h", "... 9h30".
        var h = 10, mi = 0, hasTime = false, hasMinutes = false
        var rest = s
        if let re = try? NSRegularExpression(pattern: #"(?:^|\s)(?:в |at |à )?(\d{1,2})(?:[:.h](\d{2})|h)?$"#) {
            let ns = s as NSString
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
               let hh = Int(ns.substring(with: m.range(at: 1))), hh < 24 {
                h = hh; hasTime = true
                if m.range(at: 2).location != NSNotFound { mi = Int(ns.substring(with: m.range(at: 2))) ?? 0; hasMinutes = true }
                rest = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            }
        }
        if rest.isEmpty {
            guard hasTime, hasMinutes else { return nil }   // a bare number is not a time
            var d = at(today, h, mi)
            if d <= now { d = cal.date(byAdding: .day, value: 1, to: d)! }
            return d
        }
        if !hasTime { h = 10; mi = 0 }
        if let o = offset(rest) {
            switch o.unit {
            case .day: return at(cal.date(byAdding: .day, value: o.n, to: today)!, h, mi)
            case .week: return at(cal.date(byAdding: .day, value: 7 * o.n, to: today)!, h, mi)
            case .month: return at(cal.date(byAdding: .month, value: o.n, to: today)!, h, mi)
            default: break
            }
        }
        if ["сегодня", "today", "aujourd'hui", "aujourd’hui"].contains(rest) { return at(today, h, mi) }
        if ["завтра", "tomorrow", "demain"].contains(rest) { return at(cal.date(byAdding: .day, value: 1, to: today)!, h, mi) }
        if ["послезавтра", "après-demain"].contains(rest) { return at(cal.date(byAdding: .day, value: 2, to: today)!, h, mi) }
        let days: [String: Int] = ["пн": 1, "вт": 2, "ср": 3, "чт": 4, "пт": 5, "сб": 6, "вс": 0,
                                   "пон": 1, "вто": 2, "сре": 3, "чет": 4, "пят": 5, "суб": 6, "вос": 0,
                                   "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6, "sun": 0,
                                   "lun": 1, "mar": 2, "mer": 3, "jeu": 4, "ven": 5, "sam": 6, "dim": 0]
        let w = rest.replacingOccurrences(of: #"^(в|во|on|le) "#, with: "", options: .regularExpression)
        let key: String? = w.count >= 3 && days[String(w.prefix(3))] != nil ? String(w.prefix(3))
            : w.count >= 2 && days[String(w.prefix(2))] != nil ? String(w.prefix(2)) : nil
        if let key, let wd = days[key] {
            let cur = cal.component(.weekday, from: now) - 1   // 0 = Sunday
            let d = (wd - cur + 7) % 7
            var r = at(cal.date(byAdding: .day, value: d, to: today)!, h, mi)
            if r <= now { r = cal.date(byAdding: .day, value: 7, to: r)! }
            return r
        }
        if let re = try? NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})(?:\.(\d{2}|\d{4}))?$"#) {
            let ns = rest as NSString
            if let m = re.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) {
                let day = Int(ns.substring(with: m.range(at: 1))) ?? 0, mon = Int(ns.substring(with: m.range(at: 2))) ?? 0
                let hasYear = m.range(at: 3).location != NSNotFound
                var y = hasYear ? Int(ns.substring(with: m.range(at: 3))) ?? 0 : cal.component(.year, from: now)
                if y < 100 { y += 2000 }
                guard (1...12).contains(mon), (1...31).contains(day),
                      let d = cal.date(from: DateComponents(year: y, month: mon, day: day, hour: h, minute: mi)),
                      cal.component(.day, from: d) == day else { return nil }
                if !hasYear && d <= now { return cal.date(byAdding: .year, value: 1, to: d) }
                return d
            }
        }
        if let re = try? NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})$"#) {
            let ns = rest as NSString
            if let m = re.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) {
                return cal.date(from: DateComponents(year: Int(ns.substring(with: m.range(at: 1))), month: Int(ns.substring(with: m.range(at: 2))),
                                                     day: Int(ns.substring(with: m.range(at: 3))), hour: h, minute: mi))
            }
        }
        return nil
    }

    /// What the parser does not know goes to a small model: one `claude -p` with no tools, answering a date or NONE.
    public static func ask(_ when: String, claude: String, model: String, completion: @escaping (Date?) -> Void) {
        let now = Date()
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        let tz = TimeZone.current.secondsFromGMT(for: now)
        let tzs = String(format: "%@%02d:%02d", tz >= 0 ? "+" : "-", abs(tz) / 3600, abs(tz) % 3600 / 60)
        let prompt = [
            "Now: \(f.string(from: now)) (UTC\(tzs)).",
            "A user wrote when a reminder should go off: \"\(when)\"",
            "Turn it into a local date and time. A day without a time is 10:00; a time already gone today is tomorrow.",
            "If the text names no day, date, time or period at all (it is a task, a word, gibberish), the answer is NONE - never guess.",
            "Reply with exactly one line: the time as yyyy-MM-ddTHH:mm, or NONE.",
        ].joined(separator: "\n")
        ProcessRunner.run(claude, ["-p", "--output-format", "text", "--model", model, "--tools", "",
                                   "--strict-mcp-config", "--no-session-persistence"],
                          cwd: FileManager.default.temporaryDirectory, stdin: prompt, timeout: 60) { r in
            var at: Date?
            if let m = r.stdout.firstMatch(#"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})"#) { at = ReminderStore.localFmt.date(from: m) }
            if let a = at, a < Date().addingTimeInterval(-60) { at = nil }
            completion(at)
        }
    }
}

/// Lists (shopping and any other): markdown checkboxes in Clawd's home, lists/<name>.md.
/// Lines that are not items (a heading, notes) are kept as they are.
public final class ListStore {
    public struct Item: Equatable { public var idx: Int; public var done: Bool; public var text: String }
    public var home: () -> URL
    public init(home: @escaping () -> URL) { self.home = home }

    public var dir: URL { home().appendingPathComponent("lists") }
    func path(_ name: String) -> URL { dir.appendingPathComponent("\(name).md") }

    public func names(defaultName: String = TD("lists.default", default: "Shopping")) -> [String] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = create(defaultName)
        }
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    public func read(_ name: String) -> (lines: [String], items: [Item]) {
        var lines = ((try? String(contentsOf: path(name), encoding: .utf8)) ?? "").components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.last == "" { lines.removeLast() }
        var items: [Item] = []
        for (i, l) in lines.enumerated() {
            if let r = l.range(of: #"^\s*[-*]\s+\[( |x|X)\]\s*(.*)$"#, options: .regularExpression) {
                let s = String(l[r])
                let done = s.range(of: #"\[(x|X)\]"#, options: .regularExpression) != nil
                let text = s.replacingOccurrences(of: #"^\s*[-*]\s+\[( |x|X)\]\s*"#, with: "", options: .regularExpression)
                items.append(Item(idx: i, done: done, text: text.trimmingCharacters(in: .whitespaces)))
            }
        }
        return (lines, items)
    }

    func save(_ name: String, _ lines: [String]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: path(name), atomically: true, encoding: .utf8)
    }

    /// A file name from a list name: what a file name cannot hold goes.
    public static func clean(_ name: String) -> String {
        name.replacingOccurrences(of: #"[\\/:*?"<>|\r\n]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    public func create(_ name: String) -> String? {
        let n = Self.clean(name)
        guard !n.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path(n).path) { save(n, ["# \(n)", ""]) }
        return n
    }

    public func remove(_ name: String) { try? FileManager.default.removeItem(at: path(name)) }

    /// Several at once: "milk, bread" or one per line.
    public func add(_ name: String, _ text: String) {
        guard let n = create(name) else { return }
        var lines = read(n).lines
        for t in text.components(separatedBy: CharacterSet(charactersIn: ",;\r\n")) {
            let s = t.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { lines.append("- [ ] \(s)") }
        }
        save(n, lines)
    }

    func find(_ l: (lines: [String], items: [Item]), _ what: Any) -> Item? {
        if let i = what as? Int { return l.items.first { $0.idx == i } }
        let s = "\(what)".trimmingCharacters(in: .whitespaces).lowercased()
        return l.items.first { $0.text.lowercased() == s }
    }

    @discardableResult
    public func setDone(_ name: String, _ what: Any, _ done: Bool) -> Bool {
        let l = read(name)
        guard let it = find(l, what) else { return false }
        var lines = l.lines
        lines[it.idx] = "- [\(done ? "x" : " ")] \(it.text)"
        save(name, lines)
        return true
    }

    @discardableResult
    public func removeItem(_ name: String, _ what: Any) -> Bool {
        let l = read(name)
        guard let it = find(l, what) else { return false }
        var lines = l.lines
        lines.remove(at: it.idx)
        save(name, lines)
        return true
    }

    public func clearDone(_ name: String) {
        let l = read(name)
        let drop = Set(l.items.filter(\.done).map(\.idx))
        save(name, l.lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element))
    }
}
