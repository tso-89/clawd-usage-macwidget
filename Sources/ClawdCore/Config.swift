import Foundation

/// config.json: the same keys as upstream (minus the Windows-only ones). Backed by a dictionary,
/// so keys this version does not know survive a save, and edits on disk are picked up on the fly.
public final class Config {
    public static let defaults: [String: Any] = [
        "refreshSeconds": 10,
        "usageIntervalSeconds": 60,
        "versionIntervalSeconds": 3600,
        "expanded": false,
        "scale": 1.35,
        "warnPercent": 60,
        "critPercent": 85,
        "opacity": 1.0,
        "topmost": false,
        "desktop": false,
        "trayResetClock": false,
        "showStats": true,
        "showHistory": false,
        "showStatus": true,
        "statusIntervalSeconds": 120,
        "showSessions": true,
        "remoteSessions": [String](),
        "showAccount": true,
        "accountIntervalSeconds": 600,
        "showMascot": true,
        "showSky": true,
        "weatherIntervalSeconds": 900,
        "weatherLat": NSNull(),
        "weatherLon": NSNull(),
        "showAdvisor": true,
        "advisorIntervalMinutes": 30,
        "advisorDiskGB": 10,
        "advisorJunkGB": 5,
        "advisorUnusedDays": 90,
        "advisorUptimeDays": 7,
        "advisorMemPercent": 40,
        "showChat": true,
        "chatModel": "sonnet",
        "chatTimeoutSeconds": 300,
        "chatCompact": true,
        "chatAutoRun": false,
        "chatBypass": false,
        "quickModel": "haiku",
        "showTasks": true,
        "tasksMaxPercent": 80,
        "language": "en",
        "theme": "auto",
        "accent": NSNull(),
        "skin": "classic",
        "clawdHome": NSNull(),
        "clawdSession": false,
        "clawdSessionName": "clawd-usage-macwidget",
        "clawdSessionHidden": true,
        "claudePath": NSNull(),
        "updateRepo": "",
        "left": NSNull(),
        "top": NSNull(),
    ]

    public let url: URL
    public private(set) var values: [String: Any]
    private var stamp: Date?

    public init(url: URL = Paths.data("config.json")) {
        self.url = url
        self.values = Config.defaults
        load()
    }

    public func load() {
        var v = Config.defaults
        if let raw = JSONFile.readObject(url) {
            for (k, x) in raw { v[k] = x }
        }
        values = v
        stamp = Self.modDate(url)
    }

    /// Re-reads the file if it changed on disk; returns true when it did.
    @discardableResult
    public func syncFromDisk() -> Bool {
        let s = Self.modDate(url)
        guard s != stamp else { return false }
        // The window owns its position, not the file.
        let left = values["left"], top = values["top"]
        load()
        values["left"] = left; values["top"] = top
        return true
    }

    public func save() {
        var out = JSONFile.readObject(url) ?? [:]
        for (k, x) in values { out[k] = x }
        JSONFile.write(out, to: url)
        stamp = Self.modDate(url)
    }

    public subscript(key: String) -> Any? {
        get { let v = values[key]; return v is NSNull ? nil : v }
        set { values[key] = newValue ?? NSNull() }
    }

    public func set(_ key: String, _ value: Any?) { self[key] = value; save() }

    /// A state file beside config.json, so tests with their own config never touch the real app data.
    public func dataFile(_ name: String) -> URL { url.deletingLastPathComponent().appendingPathComponent(name) }

    public func bool(_ k: String) -> Bool {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.boolValue }
        return (Config.defaults[k] as? Bool) ?? false
    }
    public func double(_ k: String) -> Double {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String, let d = Double(s) { return d }
        return (Config.defaults[k] as? NSNumber)?.doubleValue ?? 0
    }
    public func int(_ k: String) -> Int { Int(double(k)) }
    public func string(_ k: String) -> String {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return ""
    }
    public func optDouble(_ k: String) -> Double? {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String, let d = Double(s) { return d }
        return nil
    }
    public func strings(_ k: String) -> [String] {
        if let a = self[k] as? [Any] { return a.compactMap { $0 as? String }.filter { !$0.isEmpty } }
        if let s = self[k] as? String, !s.isEmpty { return [s] }
        return []
    }

    /// Clawd's home: the chat works there, reminders and tips.md live there, and so does his session.
    public var clawdHome: URL {
        var d = string("clawdHome")
        if d.isEmpty { d = Paths.home.appendingPathComponent("Clawd").path }
        let url = URL(fileURLWithPath: (d as NSString).expandingTildeInPath).standardizedFileURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func level(_ pct: Double) -> Level {
        if pct >= double("critPercent") { return .crit }
        if pct >= double("warnPercent") { return .warn }
        return .ok
    }

    private static func modDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}

public enum Level: String { case ok, warn, crit, dead }
