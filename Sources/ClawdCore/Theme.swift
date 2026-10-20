import Foundation

/// Colour themes (upstream lib/theme.ps1): semantic tokens; a theme overrides some of them,
/// `accent` in config.json overrides the accent. Level colours, the sky and Clawd are not themed.
public struct Theme: Equatable {
    public var id: String
    public var bg, code, card, card2, textHi, text, text2, text3, text4, muted, dim, faint, off, accent, accent2: String
    public var pattern: String?

    static let base: [String: String] = [
        "bg": "#1A1A1E", "code": "#141416", "card": "#26262C", "card2": "#2B3245",
        "textHi": "#F4F4F5", "text": "#E4E4E7", "text2": "#D4D4D8", "text3": "#B4B4BC", "text4": "#A1A1AA",
        "muted": "#8B8B94", "dim": "#6B7280", "faint": "#52525B", "off": "#3F3F46",
        "accent": "#60A5FA", "accent2": "#93C5FD",
    ]

    public static let ids = ["classic", "oled", "midnight", "mocha", "forest", "halloween"]

    static let overrides: [String: [String: String]] = [
        "classic": [:],
        "oled": ["bg": "#000000", "code": "#0A0A0A", "card": "#141414", "card2": "#1A2133"],
        "midnight": ["bg": "#0F172A", "code": "#0B1222", "card": "#1E293B", "card2": "#27354F",
                     "textHi": "#F1F5F9", "text": "#E2E8F0", "text2": "#CBD5E1", "text3": "#A9B6C8", "text4": "#94A3B8",
                     "muted": "#8494AB", "dim": "#64748B", "faint": "#475569", "off": "#334155",
                     "accent": "#38BDF8", "accent2": "#7DD3FC"],
        "mocha": ["bg": "#1E1E2E", "code": "#181825", "card": "#313244", "card2": "#3B3F5C",
                  "textHi": "#F5F7FF", "text": "#CDD6F4", "text2": "#BAC2DE", "text3": "#A6ADC8", "text4": "#9399B2",
                  "muted": "#9399B2", "dim": "#7F849C", "faint": "#585B70", "off": "#45475A",
                  "accent": "#89B4FA", "accent2": "#B4BEFE"],
        "forest": ["bg": "#111814", "code": "#0C120E", "card": "#1C2A21", "card2": "#233A2C",
                   "textHi": "#F0F5F1", "text": "#E1EAE3", "text2": "#CFDBD2", "text3": "#AEBFB3", "text4": "#9AAE9F",
                   "muted": "#86998B", "dim": "#66786B", "faint": "#4B5B50", "off": "#35433A",
                   "accent": "#5EEAD4", "accent2": "#99F6E4"],
        "halloween": ["bg": "#1C1326", "code": "#140E1C", "card": "#2A1D38", "card2": "#3A2550",
                      "textHi": "#FFF7ED", "text": "#F5E6DA", "text2": "#E7D3C4", "text3": "#C9B3A4", "text4": "#B39E91",
                      "muted": "#A08B9C", "dim": "#7E6A80", "faint": "#5B4A63", "off": "#3F3048",
                      "accent": "#F97316", "accent2": "#FDBA74", "pattern": "halloween"],
    ]

    /// "auto" follows the season: Halloween in September-November, classic otherwise.
    public static func resolveId(_ configured: String, now: Date = Date()) -> String {
        var id = configured.lowercased()
        if id == "auto" || id.isEmpty { id = (9...11).contains(Calendar.current.component(.month, from: now)) ? "halloween" : "classic" }
        return ids.contains(id) ? id : "classic"
    }

    public static func make(_ configured: String, accent: String) -> Theme {
        let id = resolveId(configured)
        var v = base
        for (k, x) in overrides[id] ?? [:] { v[k] = x }
        if accent.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil { v["accent"] = accent }
        return Theme(id: id, bg: v["bg"]!, code: v["code"]!, card: v["card"]!, card2: v["card2"]!, textHi: v["textHi"]!,
                     text: v["text"]!, text2: v["text2"]!, text3: v["text3"]!, text4: v["text4"]!, muted: v["muted"]!,
                     dim: v["dim"]!, faint: v["faint"]!, off: v["off"]!, accent: v["accent"]!, accent2: v["accent2"]!,
                     pattern: v["pattern"])
    }

    public static let classic = make("classic", accent: "")
}

/// Wallpaper tiles: small pixel pictures repeated faintly over the window.
public struct ThemePattern {
    public var tile: Double
    public var px: Double
    public var opacity: Double
    public var rects: [(color: String, rect: PxRect)]

    public static func named(_ name: String) -> ThemePattern? {
        guard name == "halloween" else { return nil }
        let colors: [Character: String] = ["o": "#F97316", "g": "#65A30D", "b": "#A78BFA", "w": "#F5F5F4", "y": "#FDE047"]
        let sprites: [(Double, Double, [String])] = [
            (6, 6, ["....gg...", "...g.....", ".ooo.ooo.", "ooooooooo", "oo.ooo.oo", "ooooooooo", "oo.o.o.oo", ".ooooooo."]),
            (58, 20, ["b.........b", "bb..b.b..bb", "bbbbbbbbbbb", ".bbb.b.bbb.", "..b.....b.."]),
            (30, 56, ["..www..", ".wwwww.", "ww.w.ww", "wwwwwww", "wwwwwww", "wwwwwww", "w.w.w.w"]),
            (76, 70, [".y.", "yyy", ".y."]),
            (8, 84, ["y"]),
            (92, 4, ["y"]),
        ]
        let px = 2.0
        var rects: [(String, PxRect)] = []
        for (sx, sy, art) in sprites {
            for (y, row) in art.enumerated() {
                for (x, c) in row.enumerated() {
                    if let col = colors[c] { rects.append((col, PxRect(sx + Double(x) * px, sy + Double(y) * px, px, px))) }
                }
            }
        }
        return ThemePattern(tile: 104, px: px, opacity: 0.1, rects: rects)
    }
}
