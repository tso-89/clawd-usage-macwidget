import Foundation
import Darwin

public struct Session: Equatable {
    public var name: String
    public var cwd: String
    public var busy: Bool
    public var waiting: Bool
    public var waitingFor: String
    public var kind: String
    public var sessionId: String
    public var pid: Int32
    public var started: Date?
    public var host: String?

    public init(name: String, cwd: String = "", busy: Bool = false, waiting: Bool = false, waitingFor: String = "",
                kind: String = "interactive", sessionId: String = "", pid: Int32 = 0, started: Date? = nil, host: String? = nil) {
        self.name = name; self.cwd = cwd; self.busy = busy; self.waiting = waiting; self.waitingFor = waitingFor
        self.kind = kind; self.sessionId = sessionId; self.pid = pid; self.started = started; self.host = host
    }

    /// `▶ name [what] — folder` for the hover list.
    public var hoverLine: String {
        let mark = busy ? "▶" : waiting ? "?" : "○"
        let what = waiting && !waitingFor.isEmpty ? " [\(waitingFor)]" : ""
        let whereText: String
        if let host, !host.isEmpty { whereText = cwd.isEmpty ? host : "\(host): \(cwd)" } else { whereText = cwd }
        return "\(mark) \(name)\(what) — \(whereText)"
    }
}

/// Claude Code's registry of running sessions: sessions/<pid>.json in its folder. A file can outlive
/// its process, so the process must be alive and be the same one (procStart vs. the real start time).
public enum Sessions {
    public static var dir: URL { Paths.claudeConfigDir.appendingPathComponent("sessions") }

    /// The start time of a live process, nil if it is gone.
    public static func processStart(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    /// procStart on macOS is a ctime-style UTC string ("Sun Oct 18 04:39:16 2026"); Windows writes a
    /// FILETIME. Returns nil for formats we do not know (then only liveness is checked).
    public static func parseProcStart(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["EEE MMM d HH:mm:ss yyyy", "EEE MMM  d HH:mm:ss yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        if let ft = Int64(s), ft > 100_000_000_000_000_000 {   // FILETIME: 100 ns ticks since 1601
            return Date(timeIntervalSince1970: Double(ft) / 1e7 - 11_644_473_600)
        }
        return nil
    }

    public static func fromJSON(_ j: [String: Any]) -> Session? {
        let pid = (j["pid"] as? NSNumber)?.int32Value ?? 0
        let cwd = j["cwd"] as? String ?? ""
        var name = j["name"] as? String ?? ""
        if name.isEmpty, !cwd.isEmpty { name = (cwd as NSString).lastPathComponent }
        let sid = j["sessionId"] as? String ?? ""
        if name.isEmpty, !sid.isEmpty { name = String(sid.prefix(8)) }
        let status = j["status"] as? String ?? ""
        return Session(name: name, cwd: cwd, busy: status == "busy", waiting: status == "waiting",
                       waitingFor: j["waitingFor"] as? String ?? "", kind: j["kind"] as? String ?? "",
                       sessionId: sid, pid: pid)
    }

    public static func local(dir: URL = Sessions.dir, alive: (Int32) -> Date? = processStart) -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var list: [Session] = []
        for f in files where f.pathExtension == "json" {
            guard let j = JSONFile.readObject(f), var s = fromJSON(j), s.pid > 0,
                  !ProcessRunner.ownPIDs.contains(s.pid), let start = alive(s.pid) else { continue }
            if let ps = j["procStart"] as? String, let recorded = parseProcStart(ps),
               abs(recorded.timeIntervalSince(start)) > 5 { continue }   // PID reused by another process
            s.started = start
            list.append(s)
        }
        return list.sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
    }
}

/// Sessions published by other machines (`remoteSessions`): URLs or file paths returning
/// { generatedAt, host, sessions: [...] }, already filtered to live ones by the publisher.
public final class RemoteSessions {
    public static let staleSeconds: TimeInterval = 120
    public static let hungSeconds: TimeInterval = 30

    final class Source {
        var task: URLSessionDataTask?
        var tried = Date.distantPast
        var at = Date.distantPast
        var list: [Session] = []
    }
    private var sources: [String: Source] = [:]
    private let lock = NSLock()

    public init() {}

    public static func parse(_ data: Data, now: Date = Date()) -> [Session] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var host = ""
        var items: [Any] = []
        if let j = raw as? [String: Any] {
            if let g = j["generatedAt"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let d = f.date(from: g) ?? ISO8601DateFormatter().date(from: g)
                if let d, now.timeIntervalSince(d) > staleSeconds { return [] }
            }
            host = j["host"] as? String ?? ""
            items = j["sessions"] as? [Any] ?? []
        } else if let a = raw as? [Any] { items = a }
        return items.compactMap { $0 as? [String: Any] }.compactMap {
            guard var s = Sessions.fromJSON($0) else { return nil }
            s.pid = 0; s.host = host
            return s
        }
    }

    /// Collects finished fetches, starts due ones, returns sessions from sources that answered recently.
    public func get(sources urls: [String], refresh: TimeInterval, local: [Session]) -> [Session] {
        lock.lock(); defer { lock.unlock() }
        for k in sources.keys where !urls.contains(k) { sources[k]?.task?.cancel(); sources[k] = nil }
        let now = Date()
        var out: [Session] = []
        for src in urls {
            let s = sources[src] ?? Source()
            sources[src] = s
            if let t = s.task, t.state == .running, now.timeIntervalSince(s.tried) > Self.hungSeconds { t.cancel(); s.task = nil }
            if s.task == nil || s.task?.state == .completed || s.task?.state == .canceling,
               now.timeIntervalSince(s.tried) >= refresh - 1 {
                s.tried = now
                let url: URL
                if src.range(of: #"^[a-z][a-z0-9+.-]+://"#, options: .regularExpression) != nil, let u = URL(string: src) { url = u }
                else { url = URL(fileURLWithPath: (src as NSString).expandingTildeInPath) }
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.hungSeconds)
                req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let task = URLSession.shared.dataTask(with: req) { [weak self, weak s] data, _, err in
                    guard let self, let s else { return }
                    self.lock.lock(); defer { self.lock.unlock() }
                    if let data, err == nil { s.list = Self.parse(data); s.at = Date() } else { s.list = [] }
                }
                s.task = task
                task.resume()
            }
            if now.timeIntervalSince(s.at) <= Self.staleSeconds { out += s.list }
        }
        let ids = Set(local.map(\.sessionId).filter { !$0.isEmpty })
        return out.filter { $0.sessionId.isEmpty || !ids.contains($0.sessionId) }
    }
}
