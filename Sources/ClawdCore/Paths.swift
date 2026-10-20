import Foundation

/// Where everything lives. Upstream keeps its files next to the script; on macOS app data
/// goes to Application Support, Clawd's home to ~/Clawd, Claude Code's own folder is untouched.
public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// App data: config.json, state files, history, error log. `CLAWD_DATA_DIR` overrides it
    /// (the smoke test runs a sandboxed copy this way).
    public static var dataDir: URL = {
        let env = ProcessInfo.processInfo.environment["CLAWD_DATA_DIR"]
        let dir = env.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent("Library/Application Support/ClawdUsage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static func data(_ name: String) -> URL { dataDir.appendingPathComponent(name) }

    /// Claude Code's own folder (sessions, projects, settings.json): CLAUDE_CONFIG_DIR if set, ~/.claude otherwise.
    public static var claudeConfigDir: URL {
        let env = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "").trimmingCharacters(in: .whitespaces)
        if !env.isEmpty { return URL(fileURLWithPath: (env as NSString).expandingTildeInPath) }
        return home.appendingPathComponent(".claude")
    }

    /// Claude Code's global config (trusted folders...): inside CLAUDE_CONFIG_DIR when set, ~/.claude.json otherwise.
    public static var claudeGlobalConfig: URL {
        let env = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "").trimmingCharacters(in: .whitespaces)
        if !env.isEmpty { return claudeConfigDir.appendingPathComponent(".claude.json") }
        return home.appendingPathComponent(".claude.json")
    }

    /// Bundled resources: Contents/Resources in the .app; the repo's Resources folder when run with `swift run`.
    public static var resources: URL = {
        if let r = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: r.appendingPathComponent("strings.json").path) {
            return r
        }
        if let env = ProcessInfo.processInfo.environment["CLAWD_RESOURCES"] { return URL(fileURLWithPath: env) }
        // Walk up from the executable (or this source file) to the folder holding Package.swift.
        var candidates = [URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()]
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent())
        for start in candidates {
            var d = start
            for _ in 0..<8 {
                let r = d.appendingPathComponent("Resources")
                if FileManager.default.fileExists(atPath: r.appendingPathComponent("strings.json").path) { return r }
                d = d.deletingLastPathComponent()
            }
        }
        return URL(fileURLWithPath: "Resources")
    }()

    public static func resource(_ name: String) -> URL { resources.appendingPathComponent(name) }
}

/// Appends to widget-error.log; never throws. A failing tick is logged, not fatal.
public enum ErrorLog {
    private static let queue = DispatchQueue(label: "clawd.errorlog")
    public static func write(_ context: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(context): \(message)\n"
        queue.async {
            let url = Paths.data("widget-error.log")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Small JSON file helpers used by every state file.
public enum JSONFile {
    public static func readObject(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    public static func write(_ obj: Any, to url: URL) {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? d.write(to: url, options: .atomic)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    public static func encode<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(value) { try? d.write(to: url, options: .atomic) }
    }
}
