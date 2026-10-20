import Foundation

/// All UI text: Resources/strings.json, exported from upstream lib/i18n.ps1 (scripts/export-i18n.ps1)
/// with macOS overrides in strings-mac.json. T(key) falls back to English, then to the key.
public enum I18n {
    public static let languages: [(id: String, name: String)] = [("en", "English"), ("ru", "Русский"), ("fr", "Français")]
    private static let langLock = NSLock()
    private static var _lang = "en"
    public static var lang: String {
        get { langLock.lock(); defer { langLock.unlock() }; return _lang }
        set { langLock.lock(); _lang = newValue; langLock.unlock() }
    }

    private static let tables: [String: [String: Any]] = {
        var t: [String: [String: Any]] = [:]
        for file in ["strings.json", "strings-mac.json"] {
            guard let d = try? Data(contentsOf: Paths.resource(file)),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] else { continue }
            for (l, kv) in j { t[l, default: [:]].merge(kv) { _, new in new } }
        }
        return t
    }()

    public static func raw(_ key: String) -> Any? {
        let l = lang
        return tables[l]?[key] ?? tables["en"]?[key]
    }

    public static func has(_ key: String) -> Bool { raw(key) != nil }

    public static var locale: Locale {
        Locale(identifier: ["en": "en_US", "ru": "ru_RU", "fr": "fr_FR"][lang] ?? "en_US")
    }
}

/// The string for the current language; `{0}`-style placeholders are filled from args
/// (also `{1:00}` - zero-padded), as with PowerShell's -f operator.
public func T(_ key: String, _ args: Any...) -> String {
    TD(key, default: key, args)
}

public func TD(_ key: String, default def: String, _ args: [Any] = []) -> String {
    guard let v = I18n.raw(key) else { return args.isEmpty ? def : NetFormat.format(def, args) }
    let s: String
    if let str = v as? String { s = str } else if let arr = v as? [Any] { s = arr.map { "\($0)" }.joined(separator: "|") } else { s = "\(v)" }
    return args.isEmpty ? s : NetFormat.format(s, args)
}

/// String arrays (plural forms, moon names...).
public func TA(_ key: String) -> [String] {
    if let a = I18n.raw(key) as? [Any] { return a.map { "\($0)" } }
    if let s = I18n.raw(key) as? String { return [s] }
    return []
}

/// "1 session" / "5 sessions"; French takes the singular for 0 too, Russian has three forms.
public func formatCount(_ n: Int, _ key: String) -> String {
    let f = TA("plural.\(key)")
    guard !f.isEmpty else { return "\(n)" }
    if f.count == 2 {
        let one = n == 1 || (n == 0 && I18n.lang == "fr")
        return "\(n) \(one ? f[0] : f[1])"
    }
    let d = n % 10, h = n % 100
    if d == 1 && h != 11 { return "\(n) \(f[0])" }
    if d >= 2 && d <= 4 && (h < 12 || h > 14) { return "\(n) \(f[1])" }
    return "\(n) \(f[min(2, f.count - 1)])"
}

/// A subset of .NET composite formatting: {0}, {1:00}, {0:N1}, {{ and }}.
public enum NetFormat {
    public static func format(_ s: String, _ args: [Any]) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "{" {
                let n = s.index(after: i)
                if n < s.endIndex && s[n] == "{" { out.append("{"); i = s.index(after: n); continue }
                if let close = s[i...].firstIndex(of: "}") {
                    let body = s[s.index(after: i)..<close]
                    let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
                    if let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)), idx < args.count {
                        out += render(args[idx], spec: parts.count > 1 ? parts[1] : nil)
                        i = s.index(after: close); continue
                    }
                }
            } else if c == "}" {
                let n = s.index(after: i)
                if n < s.endIndex && s[n] == "}" { out.append("}"); i = s.index(after: n); continue }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    static func render(_ v: Any, spec: String?) -> String {
        guard let spec, !spec.isEmpty else {
            if let d = v as? Double, d == d.rounded(), abs(d) < 1e12 { return String(Int(d)) }
            return "\(v)"
        }
        let num: Double? = (v as? NSNumber)?.doubleValue ?? Double("\(v)")
        if let num {
            if spec.allSatisfy({ $0 == "0" }) { return String(format: "%0\(spec.count)d", Int(num)) }
            if spec.first == "N" || spec.first == "F", let p = Int(spec.dropFirst()) { return String(format: "%.\(p)f", num) }
            if spec.hasPrefix("0."), spec.dropFirst(2).allSatisfy({ $0 == "0" || $0 == "#" }) {
                let p = spec.count - 2
                return String(format: "%.\(p)f", num)
            }
        }
        return "\(v)"
    }
}
