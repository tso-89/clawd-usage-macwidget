import Foundation

// Small probes: account, service status, Claude Code version + changelog, the widget's own release.

public struct Account: Equatable {
    public var loggedIn: Bool
    public var plan: String
    public var email: String

    static let planNames = ["max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise", "free": "Free"]

    /// `claude auth status` JSON.
    public static func parse(_ text: String) -> Account? {
        guard let d = text.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        var plan = j["subscriptionType"] as? String ?? ""
        if let p = planNames[plan] { plan = p }
        else if plan.isEmpty, let m = j["authMethod"] as? String, m != "claude.ai" { plan = "API" }
        return Account(loggedIn: j["loggedIn"] as? Bool ?? false, plan: plan, email: j["email"] as? String ?? "")
    }
}

public final class AccountProbe {
    public private(set) var account: Account?
    public private(set) var tried = Date.distantPast
    private var handle: ProcessRunner.Handle?
    public init() {}
    public func start(claude: String) {
        guard handle == nil else { return }
        tried = Date()
        handle = ProcessRunner.run(claude, ["auth", "status"], timeout: 30) { [weak self] r in
            self?.handle = nil
            if let a = Account.parse(r.stdout) { self?.account = a }
        }
    }
}

public struct ServiceStatus: Equatable {
    public struct Broken: Equatable { public var name: String; public var state: String }
    public var indicator: String
    public var incidents: [String]
    public var broken: [Broken]

    /// Statuspage summary.json.
    public static func parse(_ data: Data) -> ServiceStatus? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let ind = (j["status"] as? [String: Any])?["indicator"] as? String ?? ""
        let inc = (j["incidents"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        var broken: [Broken] = []
        for c in j["components"] as? [[String: Any]] ?? [] {
            if (c["group"] as? Bool) == true { continue }
            let st = c["status"] as? String ?? ""
            if st == "operational" { continue }
            // "Claude API (api.anthropic.com)" -> "Claude API"
            let name = (c["name"] as? String ?? "").replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
            broken.append(Broken(name: name, state: st))
        }
        return ServiceStatus(indicator: ind, incidents: inc, broken: broken)
    }
}

public enum HTTP {
    public static func get(_ url: String, timeout: TimeInterval = 20, headers: [String: String] = [:],
                           completion: @escaping (Data?) -> Void) {
        guard let u = URL(string: url) else { completion(nil); return }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("clawd-usage-macwidget", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        URLSession.shared.dataTask(with: req) { d, resp, err in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { completion(err == nil && ok ? d : nil) }
        }.resume()
    }
}

public final class StatusProbe {
    public static let page = "https://status.claude.com"
    public private(set) var status: ServiceStatus?
    public private(set) var at = Date.distantPast
    public private(set) var tried = Date.distantPast
    private var busy = false
    public init() {}
    public func start() {
        guard !busy else { return }
        busy = true; tried = Date()
        HTTP.get("\(Self.page)/api/v2/summary.json") { [weak self] d in
            self?.busy = false
            if let d, let s = ServiceStatus.parse(d) { self?.status = s; self?.at = Date() }
        }
    }
}

/// Semantic version compare on the leading x.y.z.
public struct SemVer: Comparable, CustomStringConvertible {
    public var parts: [Int]
    public init?(_ s: String) {
        guard let r = s.range(of: #"\d+(\.\d+){1,3}"#, options: .regularExpression) else { return nil }
        parts = s[r].split(separator: ".").compactMap { Int($0) }
    }
    public static func < (a: SemVer, b: SemVer) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// Claude Code's version, the latest one from the official download channel, and the changelog between them.
public final class VersionProbe {
    public static let changelogURL = "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"
    public static let changelogPage = "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"
    public private(set) var local: String?
    public private(set) var latest: String?
    public private(set) var tried = Date.distantPast
    public private(set) var changes: (forVer: String, from: String, items: [String])?
    private var changesTried = Date.distantPast
    public var updating: ProcessRunner.Handle?
    public init() {}

    public var updateAvailable: Bool {
        guard let l = local.flatMap(SemVer.init), let n = latest.flatMap(SemVer.init) else { return false }
        return n > l
    }

    public static func channel() -> String {
        let j = JSONFile.readObject(Paths.claudeConfigDir.appendingPathComponent("settings.json"))
        if let c = j?["autoUpdatesChannel"] as? String, ["stable", "latest"].contains(c) { return c }
        return "latest"
    }

    public func reset() { tried = .distantPast }

    public func start(claude: String) {
        tried = Date()
        // Re-read the local version every time: Claude Code updates itself.
        ProcessRunner.run(claude, ["--version"], timeout: 20) { [weak self] r in
            if let v = SemVer(r.stdout) { self?.local = v.description }
            self?.fetchChangelogIfNeeded()
        }
        HTTP.get("https://downloads.claude.ai/claude-code-releases/\(Self.channel())") { [weak self] d in
            if let d, let s = String(data: d, encoding: .utf8), let v = SemVer(s) { self?.latest = v.description }
            self?.fetchChangelogIfNeeded()
        }
    }

    func fetchChangelogIfNeeded() {
        guard updateAvailable, let local, let latest else { return }
        if let c = changes, c.forVer == latest, c.from == local { return }
        guard Date().timeIntervalSince(changesTried) > 600 else { return }
        changesTried = Date()
        HTTP.get(Self.changelogURL) { [weak self] d in
            guard let self, let d, let text = String(data: d, encoding: .utf8) else { return }
            self.changes = (latest, local, Self.items(text, from: local, to: latest))
        }
    }

    public static func items(_ changelog: String, from: String, to: String) -> [String] {
        guard let f = SemVer(from), let t = SemVer(to) else { return [] }
        var items: [String] = []
        for chunk in changelog.components(separatedBy: "\n## ") {
            guard let v = SemVer(String(chunk.prefix(20))), chunk.first?.isNumber == true, v > f, v <= t else { continue }
            for line in chunk.components(separatedBy: .newlines) {
                if let r = line.range(of: #"^\s*[-*]\s+(.+)$"#, options: .regularExpression) {
                    let text = line[r].replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "", options: .regularExpression)
                    items.append(text.replacingOccurrences(of: "`", with: ""))
                }
            }
        }
        return items
    }

    public func tooltip() -> String {
        guard let local, let latest else { return T("chg.open") }
        guard updateAvailable else { return T("chg.open") }
        let head = T("chg.head", local, latest)
        guard let c = changes, c.forVer == latest else { return "\(head)\n\n\(T("chg.loading"))\n\n\(T("chg.click"))" }
        var lines = c.items.prefix(25).map { "• \($0)" }
        if c.items.count > 25 { lines.append(T("chg.more", c.items.count - 25)) }
        if c.items.isEmpty { lines.append(T("chg.empty")) }
        return "\(head)\n\n\(lines.joined(separator: "\n"))\n\n\(T("chg.click"))"
    }
}

/// The widget's own releases on GitHub. Without a signed build there is no in-place update:
/// a new release turns the version line yellow, notifies once, and a click opens the release page.
public final class ReleaseProbe {
    /// owner/name on GitHub (config `updateRepo`); empty - no release check.
    public static var repo = ""
    public private(set) var latest: (ver: String, url: String, notes: String)?
    public init() {}

    public func start() {
        guard !Self.repo.isEmpty else { return }
        HTTP.get("https://api.github.com/repos/\(Self.repo)/releases/latest",
                 headers: ["Accept": "application/vnd.github+json"]) { [weak self] d in
            guard let d, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let tag = j["tag_name"] as? String, let v = SemVer(tag) else { return }
            self?.latest = (v.description, j["html_url"] as? String ?? "", j["body"] as? String ?? "")
        }
    }

    public func newer(than current: String) -> Bool {
        guard let l = latest.flatMap({ SemVer($0.ver) }), let c = SemVer(current) else { return false }
        return l > c
    }
}

/// "What's new" for the current version, from the bundled CHANGELOG.md.
public func widgetChangelogSection(_ text: String, version: String) -> [String] {
    let pat = "(?ms)^## " + NSRegularExpression.escapedPattern(for: version) + #"[^\n]*\n(.*?)(?=^## |\z)"#
    guard let re = try? NSRegularExpression(pattern: pat),
          let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return [] }
    let body = (text as NSString).substring(with: m.range(at: 1))
    return body.components(separatedBy: "\n- ").map {
        $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"^- "#, with: "", options: .regularExpression)
    }.filter { !$0.isEmpty }
}
