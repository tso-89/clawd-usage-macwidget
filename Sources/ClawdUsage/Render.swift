import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClawdCore
import SwiftUI

/// `ClawdUsage --render <dir>`: renders the widget, the panel tabs, the settings pages and a
/// reminder card to PNGs with sample data, without showing anything (upstream tools/screenshot.ps1).
/// Used for the README pictures and to check layouts by eye.
enum RenderTool {
    @MainActor static func run(_ dir: String) {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = AppModel()
        model.config["clawdHome"] = out.appendingPathComponent("home").path
        var u = Usage()
        u.session = 64; u.week = 41; u.fable = 12
        u.sessionReset = Date().addingTimeInterval(3 * 3600 + 3 * 60)
        u.weekReset = Date().addingTimeInterval(2 * 86400 + 5 * 3600)
        u.fableReset = u.weekReset
        u.day = UsagePeriod(requests: 746, sessions: 17, lines: ["35% of your usage went to always-on context over 40k tokens",
                                                                  "34% of your usage was at >150k context", "Top MCP servers: hashi 14%"])
        u.week7 = UsagePeriod(requests: 13962, sessions: 267, lines: ["58% of your usage was at >150k context"])
        model.usageProbe.inject(u)
        model.sessions = [Session(name: "api", cwd: "~/src/api", busy: true), Session(name: "web", cwd: "~/src/web", waiting: true, waitingFor: "permission"),
                          Session(name: "docs", cwd: "~/src/docs")]
        model.expanded = true
        model.config["showHistory"] = true
        let anim = Animator()
        anim.model = model
        model.mascot.setMood(sessions: model.sessions, usage: u, critPercent: 85)
        for _ in 0..<40 { anim.step() }
        let a = model.assistant
        if a.messages.isEmpty {
            a.add("user", "how much space do my caches take?")
            let m = a.add("clawd", "About 6.2 GB in ~/Library/Caches, mostly Homebrew and Chrome. I can clear the Homebrew part:",
                          run: .init(script: "brew cleanup -s && rm -rf \"$(brew --cache)\"\necho done", state: "pending", code: nil))
            _ = m
            a.add("remind", "Call the client")
            a.add("note", "Reminder Mon 19 Oct 10:00: Call the client")
        }
        a.reminders.create(at: Date().addingTimeInterval(2 * 3600), text: "Hang the laundry")
        a.lists.add("Shopping", "milk, bread, eggs")
        a.lists.setDone("Shopping", "bread", true)

        let tracker = MouseTracker()
        let badge = PanelBadge()
        badge.visible = true; badge.icon = "lightbulb"; badge.count = "2"; badge.color = Palette.warn
        let actions = WidgetActions(togglePanel: {}, toggleSettings: {}, hideWidget: {})
        save(WidgetView(model: model, anim: anim, tracker: tracker, badge: badge, actions: actions), out, "widget")
        // The sky in other weather, for the README and to check it by eye.
        anim.skySize = CGSize(width: 238, height: 43)
        for (phase, code) in [("day", 63), ("dusk", 2), ("night", 0), ("day", 73), ("day", 95)] {
            model.sky.forcePhase = phase; model.sky.forceCode = code
            for _ in 0..<30 { anim.step() }
            save(WidgetView(model: model, anim: anim, tracker: tracker, badge: badge, actions: actions)
                    .frame(height: 140, alignment: .top).clipped(), out, "sky-\(phase)-\(code)")
        }
        model.sky.forcePhase = nil; model.sky.forceCode = nil
        let ps = PanelState(model: model)
        for tab in ["chat", "remind", "lists"] {
            ps.tab = tab
            save(ClawdPanelView(state: ps, model: model, close: {}), out, "panel-\(tab)")
        }
        let r = Reminder(path: out.appendingPathComponent("x.md"), rel: "x.md", at: Date(), text: "Call the client", repeatRule: "")
        save(RemindCard(model: model, reminder: r, text: r.text, later: { _ in }, other: {}, done: {}), out, "popup")
        let sa = SettingsActions(lookNow: {}, restartSession: {}, openSkins: {})
        save(SettingsView(model: model, actions: sa).frame(width: 640, height: 900), out, "settings")
        dance(model, anim, out)
        save(SkinLineup(skins: Skins.all(home: model.config.clawdHome)), out, "skins")
        print("rendered to \(out.path)")
    }

    /// clawd-dance.gif for the README: one animation per skin, back to back.
    @MainActor static func dance(_ model: AppModel, _ anim: Animator, _ dir: URL) {
        let skins = Skins.all(home: model.config.clawdHome)
        let show: [(String, String)] = [("classic", "jump"), ("pirate", "spin"), ("viking", "celebrate"), ("robot", "skip"),
                                        ("frog", "coin-hop"), ("pumpkin", "waddle"), ("ghost", "peekaboo"), ("party", "wave"),
                                        ("crown", "turn"), ("classic", "celebrate")]
        let m = model.mascot
        m.setMood(sessions: [Session(name: "readme")], usage: nil, critPercent: 85)
        anim.areaWidth = 150
        let url = dir.appendingPathComponent("clawd-dance.gif")
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 1000, nil) else { return }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: Double(MascotEngine.frameMs) / 1000]] as CFDictionary
        var frames = 0
        func frame() {
            anim.step()
            let r = ImageRenderer(content: MascotCanvas(anim: anim, model: model).frame(width: 150, height: 64)
                .background(Color(hex: "#1E1A28")).environment(\.colorScheme, .dark))
            r.scale = 3
            if let img = r.cgImage { CGImageDestinationAddImage(gif, img, delay); frames += 1 }
        }
        for (id, act) in show {
            m.skin = skins.first { $0.id == id } ?? .classic
            m.startAct(act)
            while m.act != nil && frames < 900 { frame() }
            for _ in 0..<6 { frame() }
        }
        CGImageDestinationFinalize(gif)
    }

    @MainActor static func save<V: View>(_ v: V, _ dir: URL, _ name: String) {
        let r = ImageRenderer(content: v.environment(\.colorScheme, .dark))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("failed: \(name)"); return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

/// Every skin side by side in the default pose, for the README.
struct SkinLineup: View {
    let skins: [Skin]
    static let p = 3.0

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(18 * Self.p + 18)), count: 9), spacing: 14) {
            ForEach(skins, id: \.id) { skin in
                Canvas { ctx, _ in
                    let g = MascotGeometry.build(ClawdFrame(), skin: skin)
                    func rects(_ list: [PxRect], _ color: String) {
                        var path = Path()
                        for q in list { path.addRect(CGRect(x: 9 + q.x * Self.p, y: 24 + q.y * Self.p, width: q.w * Self.p, height: q.h * Self.p)) }
                        ctx.fill(path, with: .color(Color(hex: color)))
                    }
                    rects(g.body, skin.body)
                    rects(g.eyes, skin.eyes)
                    for a in g.acc { rects(a.rects, a.color) }
                }
                .frame(width: 18 * Self.p + 18, height: 12 * Self.p + 30)
            }
        }
        .padding(16)
        .frame(width: 9 * (18 * Self.p + 26) + 32)
        .background(Color(hex: "#1E1A28"))
    }
}
