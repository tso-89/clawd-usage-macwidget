import Foundation
import CoreServices
import Darwin

/// Clawd as a small housekeeper (upstream lib/advisor.ps1, with macOS checks): every
/// advisorIntervalMinutes a background scan looks at disk space and what takes it, new launch
/// agents, apps not opened for a long time, a long uptime, memory and CPU hogs. Read-only and
/// local: nothing is changed, a click only opens the right place. No network, no tokens.
public struct AdvisorTip: Equatable {
    public var sig: String
    public var text: String
    public var act: String?          // URL or path a click opens
    public var actLabel: String?
    public var warn = false
    public var hours: Double = 24
    public var ctx: String?
    public var startup = false
}

public struct AdvisorScan {
    public struct Disk { public var name: String; public var free: Double; public var pct: Int }
    public struct Junk { public var id: String; public var path: String; public var size: Double }
    public struct App { public var name: String; public var size: Double; public var last: Date? }
    public struct Hog { public var id: String; public var name: String; public var value: Double; public var pct: Int }
    public var disks: [Disk] = []
    public var junk: [Junk] = []
    public var startup: [String] = []
    public var apps: [App] = []
    public var uptimeDays = 0
    public var mem: [Hog] = []
    public var cpu: [Hog] = []
}

public final class Advisor {
    public private(set) var scan: AdvisorScan?
    public private(set) var at: Date?
    public private(set) var scanning = false
    private var tried: Date
    private var prevCpu = Set<String>()
    private var seen = Set<String>()
    private var snooze: [String: Date] = [:]
    private var startupKnown: [String]?
    private var statePath: URL { config.dataFile("advisor-state.json") }
    private let config: Config
    public var onChange: (() -> Void)?

    public init(config: Config) {
        self.config = config
        // The first look a minute after start: the widget comes up first.
        tried = Date().addingTimeInterval(-config.double("advisorIntervalMinutes") * 60 + 60)
        if let j = JSONFile.readObject(statePath) {
            for (k, v) in j["snooze"] as? [String: String] ?? [:] { if let d = ISO8601.parse(v) ?? ReminderStore.parseAt(v) { snooze[k] = d } }
            startupKnown = j["startupKnown"] as? [String]
        }
    }

    func saveState() {
        let iso = ISO8601DateFormatter()
        var j: [String: Any] = ["snooze": snooze.mapValues { iso.string(from: $0) }]
        if let s = startupKnown { j["startupKnown"] = s }
        JSONFile.write(j, to: statePath)
    }

    /// Every main tick: start a due scan; returns true when there are new tips (Clawd waves).
    @discardableResult
    public func update() -> Bool {
        guard config.bool("showAdvisor") else { return false }
        if !scanning && Date().timeIntervalSince(tried) >= config.double("advisorIntervalMinutes") * 60 { start() }
        let fresh = tips().filter { !seen.contains($0.sig) }
        for t in fresh { seen.insert(t.sig) }
        return !fresh.isEmpty
    }

    public func start() {
        guard !scanning else { return }
        scanning = true; tried = Date()
        let opt = (diskGB: config.double("advisorDiskGB"), unusedDays: config.double("advisorUnusedDays"),
                   memPercent: config.double("advisorMemPercent"))
        DispatchQueue.global(qos: .utility).async {
            let s = Self.run(diskGB: opt.diskGB, unusedDays: opt.unusedDays, memPercent: opt.memPercent)
            DispatchQueue.main.async {
                var s = s
                let ids = Set(s.cpu.map(\.id))
                // A hog is one seen busy in two scans in a row.
                s.cpu = s.cpu.filter { self.prevCpu.contains($0.id) }
                self.prevCpu = ids
                if self.startupKnown == nil { self.startupKnown = s.startup; self.saveState() }
                self.scan = s
                self.at = Date()
                self.scanning = false
                self.writeTipsFile()
                self.onChange?()
            }
        }
    }

    // MARK: - the scan (background)

    static func run(diskGB: Double, unusedDays: Double, memPercent: Double) -> AdvisorScan {
        var s = AdvisorScan()
        let fm = FileManager.default
        let home = Paths.home

        // Disks: local, writable volumes running low.
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
                                      .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey]
        for v in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let r = try? v.resourceValues(forKeys: Set(keys)), r.volumeIsLocal == true, r.volumeIsReadOnly != true,
                  r.volumeIsBrowsable != false, let total = r.volumeTotalCapacity, total > 4_000_000_000,
                  let free = r.volumeAvailableCapacityForImportantUsage else { continue }
            let freeGB = Double(free) / 1e9
            if freeGB < diskGB {
                s.disks.append(.init(name: r.volumeName ?? v.lastPathComponent, free: freeGB, pct: Int(100 * Double(free) / Double(total))))
            }
        }

        // What takes space: only places that are safe to look through.
        let places: [(String, URL)] = [
            ("caches", home.appendingPathComponent("Library/Caches")),
            ("logs", home.appendingPathComponent("Library/Logs")),
            ("trash", home.appendingPathComponent(".Trash")),
            ("downloads", home.appendingPathComponent("Downloads")),
            ("npm", home.appendingPathComponent(".npm")),
            ("xcode", home.appendingPathComponent("Library/Developer/Xcode/DerivedData")),
            ("gradle", home.appendingPathComponent(".gradle/caches")),
        ]
        for (id, url) in places where fm.fileExists(atPath: url.path) {
            let size = dirSize(url, deadline: Date().addingTimeInterval(20))
            if size >= 0.05 { s.junk.append(.init(id: id, path: url.path, size: size)) }
        }

        // Autostart: launch agents and daemons by their labels.
        var startup: [String] = []
        for dir in [home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"),
                    URL(fileURLWithPath: "/Library/LaunchDaemons")] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "plist" {
                let label = (NSDictionary(contentsOf: f)?["Label"] as? String) ?? f.deletingPathExtension().lastPathComponent
                if (NSDictionary(contentsOf: f)?["Disabled"] as? Bool) == true { continue }
                startup.append(label)
            }
        }
        s.startup = startup.sorted()

        // Apps not opened for a long time (Spotlight's own record), bigger than 100 MB.
        let cut = Date().addingTimeInterval(-unusedDays * 86400)
        let running = Set(ProcessRunner.runSync("/bin/ps", ["-axo", "comm="])?.stdout.components(separatedBy: "\n") ?? [])
        for dir in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            for app in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where app.pathExtension == "app" {
                if let bid = Bundle(url: app)?.bundleIdentifier, bid.hasPrefix("com.apple.") { continue }
                if running.contains(where: { $0.hasPrefix(app.path + "/") }) { continue }
                guard let item = MDItemCreateWithURL(nil, app as CFURL) else { continue }
                // No record is not "unused": many apps opened every day have none.
                guard let last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date, last < cut else { continue }
                let size = dirSize(app, deadline: Date().addingTimeInterval(5))
                if size >= 0.1 { s.apps.append(.init(name: app.deletingPathExtension().lastPathComponent, size: size, last: last)) }
            }
        }
        s.apps.sort { $0.size > $1.size }

        // Uptime.
        var tv = timeval(); var size = MemoryLayout<timeval>.stride; var mib = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &tv, &size, nil, 0) == 0 {
            s.uptimeDays = Int(Date().timeIntervalSince1970 - Double(tv.tv_sec)) / 86400
        }

        // Memory and CPU: per app (helpers summed under their app name).
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        if let ps = ProcessRunner.runSync("/bin/ps", ["-axo", "pid=,rss=,%cpu=,comm="]) {
            var mem: [String: Double] = [:]
            for line in ps.stdout.components(separatedBy: "\n") {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4, let rss = Double(parts[1]), let cpu = Double(parts[2]) else { continue }
                let comm = String(parts[3])
                let name = appName(comm)
                mem[name, default: 0] += rss * 1024
                if cpu >= 80 { s.cpu.append(.init(id: "\(parts[0])|\(name)", name: name, value: cpu, pct: Int(cpu))) }
            }
            for (name, bytes) in mem where total > 0 {
                let pct = 100 * bytes / total
                if pct >= memPercent { s.mem.append(.init(id: name, name: name, value: bytes / 1e9, pct: Int(pct))) }
            }
        }
        return s
    }

    /// "/Applications/Google Chrome.app/Contents/.../Google Chrome Helper" -> "Google Chrome".
    static func appName(_ comm: String) -> String {
        if let r = comm.range(of: #"/([^/]+)\.app/"#, options: .regularExpression) {
            let m = comm[r].dropFirst().dropLast(5)
            return String(m)
        }
        return (comm as NSString).lastPathComponent
    }

    /// Allocated size in GB, not following symlinks; stops at the deadline.
    static func dirSize(_ url: URL, deadline: Date) -> Double {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey],
                                                      options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0, n = 0
        for case let f as URL in en {
            n += 1
            if n % 2000 == 0 && Date() > deadline { break }
            guard let r = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]) else { continue }
            if r.isSymbolicLink == true { en.skipDescendants(); continue }
            total += Int64(r.totalFileAllocatedSize ?? 0)
        }
        return Double(total) / 1e9
    }

    // MARK: - tips

    static func gb(_ v: Double) -> String { v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v) }

    /// Tips from the last scan, most important first, minus dismissed ones.
    public func tips() -> [AdvisorTip] {
        guard let s = scan, config.bool("showAdvisor") else { return [] }
        var tips: [AdvisorTip] = []
        for d in s.disks {
            tips.append(AdvisorTip(sig: "disk|\(d.name)", text: T("adv.disk", d.name, Self.gb(d.free), d.pct),
                                   act: "x-apple.systempreferences:com.apple.settings.Storage", actLabel: T("adv.act.storage"), warn: true))
        }
        for c in s.cpu {
            tips.append(AdvisorTip(sig: "cpu|\(c.id)", text: T("adv.cpu", c.name, c.pct),
                                   act: "/System/Applications/Utilities/Activity Monitor.app", actLabel: T("adv.act.taskmgr")))
        }
        for m in s.mem {
            tips.append(AdvisorTip(sig: "mem|\(m.name)", text: T("adv.mem", m.name, Self.gb(m.value), m.pct),
                                   act: "/System/Applications/Utilities/Activity Monitor.app", actLabel: T("adv.act.taskmgr")))
        }
        let known = Set(startupKnown ?? [])
        let new = s.startup.filter { !known.contains($0) }
        if !new.isEmpty {
            tips.append(AdvisorTip(sig: "startup|" + new.joined(separator: "|"), text: T("adv.startup", new.prefix(3).joined(separator: ", ")),
                                   act: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension", actLabel: T("adv.act.startup"),
                                   ctx: "new launch agents: " + new.joined(separator: "; "), startup: true))
        }
        let junk = s.junk.sorted { $0.size > $1.size }
        let total = junk.reduce(0) { $0 + $1.size }
        if !junk.isEmpty && total >= config.double("advisorJunkGB") {
            let list = junk.prefix(3).map { "\(T("adv.place.\($0.id)")) \(Self.gb($0.size)) \(T("adv.gb"))" }.joined(separator: ", ")
            tips.append(AdvisorTip(sig: "junk", text: T("adv.junk", Self.gb(total), list), act: junk[0].path,
                                   actLabel: T("adv.act.open", T("adv.place.\(junk[0].id)")), hours: 72,
                                   ctx: junk.map { "\($0.id) \($0.path) \(String(format: "%.2f", $0.size)) GB" }.joined(separator: "; ")))
        }
        if !s.apps.isEmpty {
            let list = s.apps.prefix(3).map { "\($0.name) (\(Self.gb($0.size)) \(T("adv.gb")))" }.joined(separator: ", ")
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            tips.append(AdvisorTip(sig: "apps|" + s.apps.map(\.name).joined(separator: "|"),
                                   text: T("adv.apps", config.int("advisorUnusedDays"), list),
                                   act: "/Applications", actLabel: T("adv.act.apps"), hours: 24 * 30,
                                   ctx: "all unused: " + s.apps.map { "\($0.name) \(String(format: "%.2f", $0.size)) GB, last opened \($0.last.map { df.string(from: $0) } ?? "never")" }.joined(separator: "; ")))
        }
        if s.uptimeDays >= config.int("advisorUptimeDays") {
            tips.append(AdvisorTip(sig: "uptime", text: T("adv.uptime", s.uptimeDays), hours: 24 * 3))
        }
        let now = Date()
        return tips.filter { snooze[$0.sig].map { $0 < now } ?? true }
    }

    /// Dismissed: not shown again for a while; new launch agents become known instead.
    public func dismiss(_ tip: AdvisorTip) {
        if tip.startup { startupKnown = scan?.startup }
        else { snooze[tip.sig] = Date().addingTimeInterval(tip.hours * 3600) }
        let now = Date()
        snooze = snooze.filter { $0.value > now }
        saveState()
        writeTipsFile()
        onChange?()
    }

    /// The tips as a file in Clawd's home, for his own session (the phone does not see the widget).
    public func writeTipsFile() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["# Clawd's tips", "",
                     "Written by the clawd-usage-macwidget widget after each look over the Mac (every \(config.int("advisorIntervalMinutes")) min); do not edit.",
                     "Last check: \(at.map { df.string(from: $0) } ?? "none yet").", ""]
        let t = tips()
        if t.isEmpty { lines.append("Nothing to suggest right now.") }
        for tip in t {
            lines.append("- \(tip.text)")
            if let c = tip.ctx { lines.append("  Details: \(c)") }
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: config.clawdHome.appendingPathComponent("tips.md"), atomically: true, encoding: .utf8)
    }
}
