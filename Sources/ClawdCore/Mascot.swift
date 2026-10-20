import Foundation

// Clawd from the Claude Code welcome screen, built from the same block glyphs (upstream lib/mascot.ps1).
// 9 cells by 3 rows; each cell is 2x4 pixels, so the quadrant glyphs map losslessly.
// The glyph tables and animation sequences live in Resources/mascot.json (scripts/export-mascot.ps1).

public struct ClawdFrame: Hashable {
    public var eyes = "open", arms = "down", feet = "both"
    public var look = 0
    public var flip = false
    public var lift = 0.0
    public var off = 0, x = 0
    public var facing = "", poof = "", shadow = ""
    public var soul = 0.0
    public var soulT = 0
    public var dig = 0, spray = 0
    public init() {}
}

/// A rectangle in Clawd pixels (x: 0..18, y: 0..12; may go outside for sand and accessories).
public struct PxRect: Hashable {
    public var x, y, w, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct MascotGeo {
    public var body: [PxRect] = []
    public var eyes: [PxRect] = []
    public var fx: [PxRect] = []
    public var sand: [PxRect] = []
    public var acc: [(color: String, rects: [PxRect])] = []
}

public struct Skin: Equatable {
    public struct Layer: Equatable { public var color: String; public var px: [[Int]] }
    public var id: String
    public var name: String
    public var body: String
    public var eyes: String
    public var layers: [Layer]
    public static let classic = Skin(id: "classic", name: "", body: "#D77757", eyes: "#141416", layers: [])

    public var displayName: String { TD("skin.\(id)", default: name.isEmpty ? id : name) }
}

public enum Skins {
    public static func dirs(home: URL) -> [URL] {
        [Paths.resource("skins"), home.appendingPathComponent("skins")]
    }

    /// A skin file: front matter (name, body, eyes, top, one-letter colours) and 18-px-wide art.
    public static func parse(_ raw: String, id: String) -> Skin? {
        let re = try! NSRegularExpression(pattern: #"(?s)^\s*---\s*\r?\n(.*?)\r?\n---\s*\r?\n?(.*)$"#)
        let ns = raw as NSString
        guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var s = Skin(id: id.lowercased(), name: id.lowercased(), body: Skin.classic.body, eyes: Skin.classic.eyes, layers: [])
        var colors: [Character: String] = [:]
        var top: Int?
        let isColor = { (v: String) in v.range(of: #"^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"#, options: .regularExpression) != nil }
        for line in ns.substring(with: m.range(at: 1)).components(separatedBy: .newlines) {
            guard let r = line.range(of: #"^\s*(\w+)\s*:\s*(.*?)\s*$"#, options: .regularExpression) else { continue }
            let kv = String(line[r]); let parts = kv.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let k = parts[0], v = parts[1]
            switch k {
            case "name": s.name = v
            case "body": if isColor(v) { s.body = v }
            case "eyes": if isColor(v) { s.eyes = v }
            case "top": top = Int(v)
            default: if k.count == 1, isColor(v) { colors[k.first!] = v }
            }
        }
        var rows = ns.substring(with: m.range(at: 2)).components(separatedBy: .newlines).map { String($0.reversed().drop { $0 == " " || $0 == "\r" }.reversed()) }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        let t = top ?? -rows.count
        var byColor: [Character: [[Int]]] = [:]
        var order: [Character] = []
        for (y, row) in rows.enumerated() {
            for (x, c) in row.prefix(18).enumerated() where colors[c] != nil {
                if byColor[c] == nil { order.append(c) }
                byColor[c, default: []].append([x, t + y])
            }
        }
        s.layers = order.map { Skin.Layer(color: colors[$0]!, px: byColor[$0]!) }
        return s
    }

    /// All skins: classic first, then the files (the user's over the built in ones).
    public static func all(home: URL) -> [Skin] {
        var dict: [String: Skin] = ["classic": .classic]
        var order = ["classic"]
        for dir in dirs(home: home) {
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in files {
                guard let raw = try? String(contentsOf: f, encoding: .utf8),
                      let s = parse(raw, id: f.deletingPathExtension().lastPathComponent) else { continue }
                if dict[s.id] == nil { order.append(s.id) }
                dict[s.id] = s
            }
        }
        return order.compactMap { dict[$0] }
    }
}

public final class MascotData {
    public static let shared = MascotData()
    public let quad: [Character: Int]
    public let arms: [String: [String: String]]
    public let feet: [String: String]
    public let facing: [String: [(String, Int, Int)]]
    public let eyeShapes: [String: String]
    public let seqs: [String: [ClawdFrame]]
    public let actLen: [String: Int]
    public let actOrder: [String]
    public let noDemo: Set<String>
    public let clickActs: [String]
    public let entranceActs: [String]

    init() {
        let j = JSONFile.readObject(Paths.resource("mascot.json")) ?? [:]
        var q: [Character: Int] = [:]
        for (k, v) in j["quad"] as? [String: Int] ?? [:] { if let c = k.first { q[c] = v } }
        quad = q
        arms = j["arms"] as? [String: [String: String]] ?? [:]
        feet = j["feet"] as? [String: String] ?? [:]
        var fc: [String: [(String, Int, Int)]] = [:]
        for (k, v) in j["facing"] as? [String: [[Any]]] ?? [:] {
            fc[k] = v.map { ($0[0] as? String ?? "", ($0[1] as? NSNumber)?.intValue ?? 0, ($0[2] as? NSNumber)?.intValue ?? 0) }
        }
        facing = fc
        eyeShapes = j["eyes"] as? [String: String] ?? [:]
        var sq: [String: [ClawdFrame]] = [:]
        for (k, v) in j["seqs"] as? [String: [[String: Any]]] ?? [:] {
            sq[k] = v.map { d in
                var f = ClawdFrame()
                f.eyes = d["eyes"] as? String ?? "open"; f.arms = d["arms"] as? String ?? "down"
                f.feet = d["feet"] as? String ?? "both"; f.off = (d["off"] as? NSNumber)?.intValue ?? 0
                f.x = (d["x"] as? NSNumber)?.intValue ?? 0; f.facing = d["facing"] as? String ?? ""
                f.poof = d["poof"] as? String ?? ""; f.shadow = d["shadow"] as? String ?? ""
                return f
            }
        }
        seqs = sq
        // JSONSerialization loses key order - the act order is fixed here, as upstream.
        let order = ["jump", "look", "celebrate", "skip", "spin", "peekaboo", "drop", "waddle", "peek", "wink", "boop",
                    "tap", "sneeze", "turn", "coin-hop", "wave", "stretch", "yawn", "stumble", "soul", "burrow", "unburrow", "stir"]
        actOrder = order
        var len: [String: Int] = [:]
        var nd = Set<String>()
        for (k, v) in j["acts"] as? [String: [String: Any]] ?? [:] {
            len[k] = (v["len"] as? NSNumber)?.intValue ?? 0
            if (v["noDemo"] as? Bool) == true { nd.insert(k) }
        }
        actLen = len
        noDemo = nd
        clickActs = (j["clickActs"] as? [String] ?? []).sorted { order.firstIndex(of: $0) ?? 0 < order.firstIndex(of: $1) ?? 0 }
        entranceActs = j["entranceActs"] as? [String] ?? []
    }
}

public enum MascotGeometry {
    public static let cols = 9, rows = 3
    public static let W = 18, H = 12
    public static let burrowDig = 4

    private static var cache: [String: MascotGeo] = [:]
    private static let lock = NSLock()
    public static func clearCache() { lock.lock(); cache = [:]; lock.unlock() }

    /// Frame -> rectangles: body, eyes (black), fx (dust, shadow), sand, accessories by colour.
    public static func build(_ f: ClawdFrame, skin: Skin) -> MascotGeo {
        let key = "\(skin.id)|\(skin.layers.count)|\(f.eyes)|\(f.arms)|\(f.feet)|\(f.look)|\(f.flip)|\(f.off)|\(f.x)|\(f.facing)|\(f.poof)|\(f.shadow)|\(f.dig)|\(f.spray)"
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }
        let d = MascotData.shared
        var g = Array(repeating: Array(repeating: 0, count: H), count: W)   // 0 empty, 1 body, 2 black

        func paint(_ glyphs: String, _ col: Int, _ row: Int, _ mode: String) {
            for (i, c) in glyphs.enumerated() {
                let fg = mode == "lid" ? 2 : 1
                let bg = mode == "eyes" ? 2 : mode == "lid" ? 1 : 0
                for sy in 0..<4 {
                    for sx in 0..<2 {
                        let on: Bool
                        if c == "▂" { on = sy == 3 } else {
                            let bit = (sy < 2 ? 1 : 4) * (sx == 1 ? 2 : 1)
                            on = ((d.quad[c] ?? 0) & bit) != 0
                        }
                        let v = on ? fg : bg
                        let px = 2 * (col + i) + sx, py = 4 * row + sy
                        if v != 0, px >= 0, px < W, py < H { g[px][py] = v }
                    }
                }
            }
        }
        func sub(_ s: String, _ a: Int, _ b: Int) -> String {
            let arr = Array(s); return String(arr[max(0, min(a, arr.count))..<max(0, min(b, arr.count))])
        }

        if !f.facing.isEmpty, let rowsDef = d.facing[f.facing] {
            for (r, def) in rowsDef.enumerated() {
                let (s, from, to) = def
                paint(sub(s, 0, from), 0, r, "")
                paint(sub(s, from, to), from, r, "eyes")
                paint(sub(s, to, s.count), to, r, "")
            }
        } else {
            let a = d.arms[f.arms] ?? d.arms["down"] ?? [:]
            paint(a["r1L"] ?? "", 0, 0, "")
            paint("██████", 2, 0, "eyes")
            paint(a["r1R"] ?? "", 8, 0, "")
            paint(a["r2L"] ?? "", 0, 1, "")
            paint("█████", 2, 1, "eyes")
            paint(a["r2R"] ?? "", 7, 1, "")
            paint(d.feet[f.feet] ?? d.feet["both"] ?? "", 0, 2, "")

            // Looking sideways with normal eyes - ready-made poses; other expressions shift the pupils.
            var eyes = f.eyes, shift = 0
            if eyes == "open" && f.look < 0 { eyes = "left" }
            else if eyes == "open" && f.look > 0 { eyes = "right" }
            else if !["open", "left", "right", "wink"].contains(eyes) { shift = f.look }
            let sh = (d.eyeShapes[eyes] ?? d.eyeShapes["open"] ?? "1,2 1,3").split(separator: ";").map(String.init)
            let ex = [4, 12]
            for k in 0..<2 {
                for pt in sh[min(k, sh.count - 1)].split(separator: " ") {
                    let xy = pt.split(separator: ",").compactMap { Int($0) }
                    guard xy.count == 2 else { continue }
                    let px = ex[k] + xy[0] + shift
                    if px >= 0, px < W, xy[1] < H { g[px][xy[1]] = 2 }
                }
            }
            if eyes == "yawn" || eyes == "gasp" { for x in 8...10 { g[x][4] = 2; g[x][5] = 2 } }
        }

        var geo = MascotGeo()
        let oy = 4 * f.off + f.dig, ox = 2 * f.x
        let lim = f.dig > 0 ? H - 2 : H
        for y in 0..<H {
            var sy = y
            if f.flip { if y >= H - 2 { continue } else { sy = H - 3 - y } }
            let yy = sy + oy
            if yy < 0 || yy >= lim { continue }
            var x = 0
            while x < W {
                let c = g[x][y]
                if c == 0 { x += 1; continue }
                let x0 = x
                while x < W && g[x][y] == c { x += 1 }
                let l = max(0, x0 + ox), rr = min(W, x + ox)
                if rr <= l { continue }
                let rect = PxRect(Double(l), Double(yy), Double(rr - l), 1)
                if c == 2 { geo.eyes.append(rect) } else { geo.body.append(rect) }
            }
        }
        // Accessories: above the head while the head is in the frame; on his back he loses them.
        for layer in skin.layers {
            var rects: [PxRect] = []
            if !f.flip {
                for p in layer.px {
                    let x = p[0] + ox, y = p[1]
                    if y >= 0 && !f.facing.isEmpty { continue }
                    let yy = y + oy
                    if x < 0 || x >= W || yy >= lim { continue }
                    if y < 0 ? oy < 0 : yy < 0 { continue }
                    rects.append(PxRect(Double(x), Double(yy), 1, 1))
                }
            }
            geo.acc.append((layer.color, rects))
        }
        // Dust "·" and "~" at the edges of the bottom row while crouched.
        if !f.poof.isEmpty && f.off > 0 {
            for cx in [0.0, Double(W - 2)] {
                let pts: [[Double]] = f.poof == "dot" ? [[0.6, 9.4, 0.8, 0.9]] : [[0, 9.6, 0.7, 0.6], [0.7, 9.1, 0.6, 0.6], [1.3, 9.6, 0.7, 0.6]]
                for p in pts { geo.fx.append(PxRect(cx + p[0], p[1], p[2], p[3])) }
            }
        }
        if !f.shadow.isEmpty {
            let (sc, sw) = f.shadow == "wide" ? (6.0, 6.0) : (8.0, 2.0)
            geo.fx.append(PxRect(sc, Double(H) - 0.5, sw, 0.5))
        }
        // Sand mound over the burrow, and grains flying from under the legs.
        let Hd = Double(H), Wd = Double(W)
        if f.dig >= 1 { geo.sand.append(PxRect(-2, Hd - 3, Wd + 4, 1)) }
        if f.dig >= 2 { geo.sand.append(PxRect(-1, Hd - 4, Wd + 2, 1)) }
        if f.dig >= 3 { geo.sand.append(PxRect(-1, Hd - 5, 2, 1)); geo.sand.append(PxRect(Wd - 1, Hd - 5, 2, 1)) }
        if f.spray > 0 {
            for k in 0..<2 {
                let dd = Double(f.spray + 2 * k)
                let sx = 1.5 + 0.9 * dd, sy = (Hd - 4) - 0.9 * dd * (5 - dd) / 2
                geo.sand.append(PxRect(-sx, sy, 0.8, 0.8))
                geo.sand.append(PxRect(Wd - 0.8 + sx, sy, 0.8, 0.8))
            }
        }
        lock.lock()
        if cache.count > 4000 { cache = [:] }
        cache[key] = geo
        lock.unlock()
        return geo
    }

    // Soul: a translucent mini-Clawd on a thread from the mouth.
    static let soulArt = ["..########..", "..#.####.#..", "############", "..########..", "...######...", "....####....", ".....##....."]
    public static let soulPx = 1.4

    /// Rectangles in points with the origin at the mouth (y up is negative).
    public static func soul(height h: Double, t: Int) -> [PxRect] {
        let p = soulPx
        var out: [PxRect] = []
        let sway = 2.5 * sin(Double(t) / 4)
        let n = Int(floor(h / p))
        for i in 0..<max(0, n) {
            let k = Double(i) / Double(max(1, n))
            let dx = sway * k + 1.2 * sin(Double(t) / 2 + Double(i) * 0.7) * sin(k * .pi)
            out.append(PxRect((dx / p).rounded() * p - p / 2, -Double(i + 1) * p, p, p))
        }
        let top = -h - Double(soulArt.count) * p
        let x0 = (sway / p).rounded() * p - 6 * p
        for (y, row) in soulArt.enumerated() {
            let chars = Array(row); var x = 0
            while x < chars.count {
                if chars[x] != "#" { x += 1; continue }
                let a = x
                while x < chars.count && chars[x] == "#" { x += 1 }
                out.append(PxRect(x0 + Double(a) * p, top + Double(y) * p, Double(x - a) * p, p))
            }
        }
        return out
    }

    public static let heartRows = [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]
    /// A heart (full: maxCol 6, half: 3) in heart pixels.
    public static func heart(maxCol: Int) -> [PxRect] {
        var out: [PxRect] = []
        for (y, row) in heartRows.enumerated() {
            for (x, c) in row.enumerated() where x <= maxCol && c == "#" { out.append(PxRect(Double(x), Double(y), 1, 1)) }
        }
        return out
    }
}
