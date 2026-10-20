import Foundation

/// The 5-hour and weekly percentages over the last 7 days (usage-history.json, one sample per
/// /usage reply), and which projects spent the most (from Claude Code's transcripts, tokens
/// weighted by the model's price). Upstream: lib/history.ps1.
public final class UsageHistory {
    public static let keepDays = 8.0
    public static let stepMinutes = 5
    public static let gapMinutes = 20
    public static let projScanMinutes = 15.0

    public struct Sample: Equatable { public var minute: Int; public var session: Int; public var week: Int }

    public private(set) var samples: [Sample] = []
    public private(set) var backfilled = false
    public private(set) var projects: Projects?
    public private(set) var projAt: Date?
    private var projTry = Date.distantPast
    private var scanning = false
    private var cache: [String: FileCache] = [:]
    private let url: URL
    private let queue = DispatchQueue(label: "clawd.history", qos: .utility)

    public struct Projects {
        public var total: [String: Double]
        public var hours: [Int: [String: Double]]
        public var paths: [String: String]
        public var top: [(name: String, share: Double, path: String)] {
            let sum = total.values.reduce(0, +)
            guard sum > 0 else { return [] }
            return total.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, 100 * $0.value / sum, paths[$0.key] ?? $0.key) }
        }
    }

    final class FileCache {
        var pos: UInt64 = 0
        var ids = Set<String>()
        var dir: String
        var cwd: String?
        var w: [Int: Double] = [:]
        init(dir: String) { self.dir = dir }
    }

    public init(url: URL = Paths.data("usage-history.json")) {
        self.url = url
        if let j = JSONFile.readObject(url) {
            backfilled = j["backfilled"] as? Bool ?? false
            for s in j["samples"] as? [[NSNumber]] ?? [] where s.count >= 3 {
                samples.append(Sample(minute: s[0].intValue, session: s[1].intValue, week: s[2].intValue))
            }
        }
    }

    public static func minute(_ d: Date) -> Int { Int(floor(d.timeIntervalSince1970 / 60)) }

    public func add(_ u: Usage, now: Date = Date()) {
        let s = u.session ?? -1, w = u.week ?? -1, m = Self.minute(now)
        if let last = samples.last, last.session == s, last.week == w, m - last.minute < Self.stepMinutes { return }
        samples.append(Sample(minute: m, session: s, week: w))
        save()
    }

    public func save() {
        let cut = Self.minute(Date().addingTimeInterval(-Self.keepDays * 86400))
        samples.removeAll { $0.minute < cut }
        JSONFile.write(["backfilled": backfilled, "samples": samples.map { [$0.minute, $0.session, $0.week] }] as [String: Any], to: url)
    }

    /// The sample at or before minute `t`, if within the gap limit.
    public func sample(at t: Int) -> Sample? {
        var lo = 0, hi = samples.count - 1
        var hit: Sample?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if samples[mid].minute <= t { hit = samples[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let h = hit, t - h.minute <= Self.gapMinutes else { return nil }
        return h
    }

    /// Runs of points (x 0..1, y 0..1 where 1 = 100%) without gaps, for one series (1: session, 2: week).
    public func runs(series: Int, from t0: Int, to t1: Int) -> [[(Double, Double)]] {
        var out: [[(Double, Double)]] = []
        var run: [(Double, Double)] = []
        var prev: Int?
        for s in samples where s.minute >= t0 {
            let v = series == 1 ? s.session : s.week
            if v < 0 || (prev != nil && s.minute - prev! > Self.gapMinutes) { if !run.isEmpty { out.append(run) }; run = [] }
            prev = s.minute
            if v >= 0 { run.append((Double(s.minute - t0) / Double(t1 - t0), Double(min(100, v)) / 100)) }
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    public func updateProjectsIfDue(enabled: Bool) {
        guard enabled else { return }
        if !backfilled { backfill() }
        guard !scanning, Date().timeIntervalSince(projTry) >= Self.projScanMinutes * 60 else { return }
        projTry = Date(); scanning = true
        let root = Paths.claudeConfigDir.appendingPathComponent("projects")
        let since = Self.minute(Date().addingTimeInterval(-7 * 86400))
        queue.async { [self] in
            let r = Self.scan(root: root, cache: &self.cache, since: since)
            DispatchQueue.main.async { self.projects = r; self.projAt = Date(); self.scanning = false }
        }
    }

    /// Transcripts of /usage probes run with persistence (none for this port, but kept for
    /// parity: a probe started from our data folder would land in that project folder).
    func backfill() {
        backfilled = true
        let slug = Paths.dataDir.path.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let dir = Paths.claudeConfigDir.appendingPathComponent("projects").appendingPathComponent(slug)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var add: [Sample] = []
        let stop = samples.first?.minute ?? Int.max
        for f in files where f.pathExtension == "jsonl" {
            guard let t = try? String(contentsOf: f, encoding: .utf8), t.count < 65536,
                  t.contains("<command-name>/usage</command-name>") else { continue }
            let s = t.firstMatch(#"Current session:\s*(\d+)%"#).flatMap { Int($0) } ?? -1
            let w = t.firstMatch(#"Current week \(all models\):\s*(\d+)%"#).flatMap { Int($0) } ?? -1
            guard s >= 0 || w >= 0, let ts = t.firstMatch(#""timestamp":"([^"]+)""#), let d = ISO8601.parse(ts) else { continue }
            let m = Self.minute(d)
            if m < stop { add.append(Sample(minute: m, session: s, week: w)) }
        }
        samples.insert(contentsOf: add.sorted { $0.minute < $1.minute }, at: 0)
        save()
    }

    // Price of a million input tokens; first match wins, so versions go first.
    static let prices: [(String, Double)] = [("fable", 10), ("mythos", 10), ("opus-5-5", 4), ("opus", 5),
                                             ("sonnet-5", 2), ("sonnet", 3), ("haiku-5", 0.1), ("haiku", 1)]
    // Cache writes, cache reads and output relative to input.
    static let kinds: [(String, Double)] = [("input_tokens", 1), ("cache_creation_input_tokens", 1.25),
                                            ("cache_read_input_tokens", 0.1), ("output_tokens", 5)]

    static let usageMark = Data("\"usage\":{\"input_tokens\"".utf8)
    static let cwdMark = Data("\"cwd\":\"".utf8)

    static func scanLine(_ lineSub: Data.SubSequence, _ fc: FileCache, _ firstHour: Int) {
        let hasUsage = lineSub.range(of: usageMark) != nil
        guard hasUsage || (fc.cwd == nil && lineSub.range(of: cwdMark) != nil) else { return }
        let line = String(decoding: lineSub, as: UTF8.self)
        if fc.cwd == nil, let cwd = line.firstMatch(#""cwd":"((?:[^"\\]|\\.)*)""#) { fc.cwd = cwd.replacingOccurrences(of: "\\\\", with: "\\") }
        guard hasUsage else { return }
        if let id = line.firstMatch(#""id":"(msg_[^"]+)""#) {
            if fc.ids.contains(id) { return }
            fc.ids.insert(id)
        }
        let model = line.firstMatch(#""model":"([^"]+)""#) ?? ""
        if model == "<synthetic>" { return }
        guard let ts = line.firstMatch(#""timestamp":"([^"]+)""#), let at = ISO8601.parse(ts) else { return }
        let hour = Int(floor(at.timeIntervalSince1970 / 3600))
        if hour < firstHour { return }
        let price = prices.first { model.contains($0.0) }?.1 ?? 3
        var tok = 0.0
        for (k, m) in kinds { if let v = line.firstMatch("\"\(k)\":(\\d+)"), let d = Double(v) { tok += m * d } }
        fc.w[hour, default: 0] += price * tok
    }

    static func scan(root: URL, cache: inout [String: FileCache], since: Int) -> Projects {
        let fm = FileManager.default
        let from = Date(timeIntervalSince1970: Double(since) * 60)
        let firstHour = since / 60
        var seen = Set<String>()
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for pd in dirs {
            guard let en = fm.enumerator(at: pd, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let f as URL in en where f.pathExtension == "jsonl" {
                let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let mod = rv?.contentModificationDate, mod >= from, let size = rv?.fileSize else { continue }
                seen.insert(f.path)
                var c = cache[f.path]
                if c == nil || UInt64(size) < c!.pos { c = FileCache(dir: pd.lastPathComponent); cache[f.path] = c }
                guard let fc = c, UInt64(size) != fc.pos, let h = try? FileHandle(forReadingFrom: f) else { continue }
                // Streamed in chunks: a week of transcripts can be a gigabyte. Only whole lines count;
                // one still being written waits for the next scan.
                try? h.seek(toOffset: fc.pos)
                var carry = Data()
                while autoreleasepool(invoking: { () -> Bool in
                    guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                    carry.append(chunk)
                    guard let end = carry.lastIndex(of: 0x0A) else { return true }
                    let whole = carry[carry.startIndex...end]
                    fc.pos += UInt64(whole.count)
                    for lineSub in whole.split(separator: 0x0A) { scanLine(lineSub, fc, firstHour) }
                    carry = Data(carry[carry.index(after: end)...])
                    return true
                }) {}
                try? h.close()
            }
        }
        for k in cache.keys where !seen.contains(k) { cache[k] = nil }
        var cwds: [String: String] = [:]
        for c in cache.values { if let cwd = c.cwd, cwds[c.dir] == nil { cwds[c.dir] = cwd } }
        let home = Paths.home.path
        var r = Projects(total: [:], hours: [:], paths: [:])
        for c in cache.values {
            let cwd = cwds[c.dir] ?? c.dir
            let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            var name = trimmed == home ? "~" : (trimmed as NSString).lastPathComponent
            if name.isEmpty { name = cwd }
            r.paths[name] = cwd
            for (h, w) in c.w where h >= firstHour {
                r.total[name, default: 0] += w
                r.hours[h, default: [:]][name, default: 0] += w
            }
        }
        return r
    }
}

public enum ISO8601 {
    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

extension String {
    /// First capture group of a regex, or nil.
    public func firstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let re = RegexCache.get(pattern, options) else { return nil }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
}

/// Compiled patterns, reused: the transcript scan runs the same few on every line.
enum RegexCache {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()
    static func get(_ p: String, _ o: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(o.rawValue)|\(p)"
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        let r = try? NSRegularExpression(pattern: p, options: o)
        if cache.count > 500 { cache = [:] }
        cache[key] = r
        return r
    }
}
