import Foundation

/// A JSON value that keeps object key order, so editing one key of Claude Code's settings.json
/// leaves every other one exactly where it was.
public indirect enum OJSON: Equatable {
    case null, bool(Bool), number(String), string(String), array([OJSON]), object([(String, OJSON)])

    public static func == (a: OJSON, b: OJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> OJSON? {
        if case let .object(kv) = self { return kv.first { $0.0 == key }?.1 }
        return nil
    }

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var intValue: Int? { if case let .number(n) = self { return Int(Double(n) ?? 0) }; return nil }

    // MARK: parse

    public struct ParseError: Error, CustomStringConvertible { public var description: String }

    public static func parse(_ text: String) throws -> OJSON {
        var p = Parser(Array(text.unicodeScalars))
        p.skip()
        let v = try p.value()
        p.skip()
        if p.i < p.s.count { throw ParseError(description: "unexpected text at \(p.i)") }
        return v
    }

    struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }
        mutating func skip() { while i < s.count, [" ", "\n", "\r", "\t"].contains(s[i]) { i += 1 } }
        mutating func expect(_ c: Unicode.Scalar) throws {
            skip()
            guard i < s.count, s[i] == c else { throw ParseError(description: "expected \(c) at \(i)") }
            i += 1
        }
        mutating func value() throws -> OJSON {
            skip()
            guard i < s.count else { throw ParseError(description: "unexpected end") }
            switch s[i] {
            case "{":
                i += 1; var kv: [(String, OJSON)] = []
                skip()
                if i < s.count, s[i] == "}" { i += 1; return .object(kv) }
                while true {
                    skip()
                    let k = try string()
                    try expect(":")
                    kv.append((k, try value()))
                    skip()
                    if i < s.count, s[i] == "," { i += 1; continue }
                    try expect("}"); return .object(kv)
                }
            case "[":
                i += 1; var a: [OJSON] = []
                skip()
                if i < s.count, s[i] == "]" { i += 1; return .array(a) }
                while true {
                    a.append(try value())
                    skip()
                    if i < s.count, s[i] == "," { i += 1; continue }
                    try expect("]"); return .array(a)
                }
            case "\"": return .string(try string())
            case "t": try word("true"); return .bool(true)
            case "f": try word("false"); return .bool(false)
            case "n": try word("null"); return .null
            default:
                let start = i
                while i < s.count, "+-0123456789.eE".unicodeScalars.contains(s[i]) { i += 1 }
                guard i > start else { throw ParseError(description: "bad value at \(i)") }
                return .number(String(String.UnicodeScalarView(s[start..<i])))
            }
        }
        mutating func word(_ w: String) throws {
            for c in w.unicodeScalars {
                guard i < s.count, s[i] == c else { throw ParseError(description: "bad literal at \(i)") }
                i += 1
            }
        }
        mutating func string() throws -> String {
            guard i < s.count, s[i] == "\"" else { throw ParseError(description: "expected string at \(i)") }
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]; i += 1
                if c == "\"" { return String(out) }
                if c == "\\" {
                    guard i < s.count else { break }
                    let e = s[i]; i += 1
                    switch e {
                    case "n": out.append("\n"); case "r": out.append("\r"); case "t": out.append("\t")
                    case "b": out.append("\u{8}"); case "f": out.append("\u{C}")
                    case "u":
                        guard i + 4 <= s.count, var code = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16) else { throw ParseError(description: "bad escape") }
                        i += 4
                        if (0xD800...0xDBFF).contains(code), i + 6 <= s.count, s[i] == "\\", s[i + 1] == "u",
                           let lo = UInt32(String(String.UnicodeScalarView(s[i + 2..<i + 6])), radix: 16) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00); i += 6
                        }
                        if let u = Unicode.Scalar(code) { out.append(u) }
                    default: out.append(e)
                    }
                } else { out.append(c) }
            }
            throw ParseError(description: "unterminated string")
        }
    }

    // MARK: serialize - like JSON.stringify(v, null, 2)

    static func quote(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case "\u{8}": o += "\\b"
            case "\u{C}": o += "\\f"
            default: if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
            }
        }
        return o + "\""
    }

    public func serialized(_ ind: String = "") -> String {
        let in2 = ind + "  "
        switch self {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(n): return n
        case let .string(s): return Self.quote(s)
        case let .array(a): return a.isEmpty ? "[]" : "[\n" + a.map { in2 + $0.serialized(in2) }.joined(separator: ",\n") + "\n\(ind)]"
        case let .object(kv): return kv.isEmpty ? "{}" : "{\n" + kv.map { in2 + Self.quote($0.0) + ": " + $0.1.serialized(in2) }.joined(separator: ",\n") + "\n\(ind)}"
        }
    }

    /// Sets (or with nil removes) a dotted key; an object left empty by a removal goes too.
    public mutating func set(_ path: String, _ value: OJSON?) {
        self = Self.setting(self, path.split(separator: ".").map(String.init)[...], value) ?? .object([])
    }

    static func setting(_ node: OJSON, _ parts: ArraySlice<String>, _ value: OJSON?) -> OJSON? {
        guard let key = parts.first else { return value }
        var kv: [(String, OJSON)]
        if case let .object(o) = node { kv = o } else { kv = [] }
        let idx = kv.firstIndex { $0.0 == key }
        let child = idx.map { kv[$0].1 } ?? .object([])
        let rest = parts.dropFirst()
        if value == nil && idx == nil { return node }
        let newChild: OJSON?
        if rest.isEmpty { newChild = value } else {
            if value == nil, case .object = child {} else if value == nil { return node }
            newChild = setting(child, rest, value)
        }
        if let nc = newChild {
            if !rest.isEmpty, value == nil, case let .object(o) = nc, o.isEmpty {
                if let idx { kv.remove(at: idx) }
            } else if let idx { kv[idx].1 = nc } else { kv.append((key, nc)) }
        } else if let idx { kv.remove(at: idx) }
        return .object(kv)
    }

    public func get(_ path: String) -> OJSON? {
        var cur: OJSON? = self
        for p in path.split(separator: ".") { cur = cur?[String(p)] }
        return cur
    }
}

/// Claude Code's own ~/.claude/settings.json: a picked set of keys for the Settings tab.
/// Only the changed key is rewritten; the file before the first change is kept as settings.json.clawd-bak.
public final class ClaudeSettings {
    public struct Item {
        public var key: String
        public var kind: String          // toggle, choice, days, attribution, head
        public var opts: [String] = []
        public var def: String?
        public var steps: [Int] = []
    }

    public static let items: [Item] = [
        Item(key: "cc.hModel", kind: "head"),
        Item(key: "model", kind: "choice", opts: ["", "opus", "sonnet", "haiku", "fable"]),
        Item(key: "fastMode", kind: "toggle", def: "false"),
        Item(key: "language", kind: "choice", opts: ["", "english", "russian", "french"]),
        Item(key: "permissions.defaultMode", kind: "choice", opts: ["default", "acceptEdits", "plan", "auto"], def: "default"),
        Item(key: "cc.hWork", kind: "head"),
        Item(key: "autoCompactEnabled", kind: "toggle", def: "true"),
        Item(key: "autoMemoryEnabled", kind: "toggle", def: "true"),
        Item(key: "fileCheckpointingEnabled", kind: "toggle", def: "true"),
        Item(key: "awaySummaryEnabled", kind: "toggle", def: "true"),
        Item(key: "respondToBashCommands", kind: "toggle", def: "true"),
        Item(key: "attribution", kind: "attribution"),
        Item(key: "cleanupPeriodDays", kind: "days", def: "30", steps: [7, 14, 30, 60, 90, 180, 365]),
        Item(key: "autoUpdatesChannel", kind: "choice", opts: ["latest", "stable"], def: "latest"),
        Item(key: "cc.hTerminal", kind: "head"),
        Item(key: "theme", kind: "choice", opts: ["auto", "dark", "light", "dark-daltonized", "light-daltonized", "dark-ansi", "light-ansi"], def: "dark"),
        Item(key: "tui", kind: "choice", opts: ["", "fullscreen", "default"]),
        Item(key: "outputStyle", kind: "choice", opts: ["", "Proactive", "Explanatory", "Learning"]),
        Item(key: "viewMode", kind: "choice", opts: ["", "default", "verbose", "focus"]),
        Item(key: "editorMode", kind: "choice", opts: ["normal", "vim"], def: "normal"),
        Item(key: "spinnerTipsEnabled", kind: "toggle", def: "true"),
        Item(key: "showTurnDuration", kind: "toggle", def: "true"),
        Item(key: "showThinkingSummaries", kind: "toggle", def: "false"),
        Item(key: "terminalProgressBarEnabled", kind: "toggle", def: "true"),
        Item(key: "prefersReducedMotion", kind: "toggle", def: "false"),
        Item(key: "cc.hRemote", kind: "head"),
        Item(key: "remoteControlAtStartup", kind: "toggle", def: "false"),
        Item(key: "agentPushNotifEnabled", kind: "toggle", def: "false"),
        Item(key: "inputNeededNotifEnabled", kind: "toggle", def: "false"),
    ]

    public let url: URL
    private var backedUp = false
    public private(set) var root: OJSON = .object([])
    public private(set) var error: String?
    private var stamp: Date?

    public init(url: URL = Paths.claudeConfigDir.appendingPathComponent("settings.json")) {
        self.url = url
        reload()
    }

    /// Read anew only when the file changed.
    public func reload() {
        let s = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if s == stamp && s != nil { return }
        stamp = s
        error = nil
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            root = .object([]); return
        }
        do {
            let v = try OJSON.parse(text)
            guard case .object = v else { throw OJSON.ParseError(description: "not a JSON object") }
            root = v
        } catch {
            root = .object([]); self.error = "\(error)"
        }
    }

    public func get(_ key: String) -> OJSON? { reload(); return root.get(key) }

    /// Several keys in one write; nil removes a key.
    public func set(_ changes: [(String, OJSON?)]) {
        reload()
        guard error == nil else { return }
        var r = root
        for (k, v) in changes { r.set(k, v) }
        let fm = FileManager.default
        do {
            if !backedUp && fm.fileExists(atPath: url.path) {
                let bak = URL(fileURLWithPath: url.path + ".clawd-bak")
                try? fm.removeItem(at: bak)
                try fm.copyItem(at: url, to: bak)
                backedUp = true
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (r.serialized() + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ErrorLog.write("settings.json", "\(error)")
        }
        stamp = nil
        reload()
    }
}
