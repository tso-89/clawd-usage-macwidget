import AppKit
import ClawdCore
import SwiftUI

/// Steps Clawd and the sky (60 ms for Claude Code's animations, 90 ms otherwise) and publishes
/// what to draw. Runs only while the widget is on screen.
final class Animator: ObservableObject {
    @Published var mascot = MascotRender()
    @Published var sky = SkyRender()
    var areaWidth: Double = 150
    var skySize: CGSize = .zero
    var mouseX: Double?
    var mouseOver = false
    private var timer: Timer?
    private var interval = 90
    weak var model: AppModel?

    func start() {
        guard timer == nil else { return }
        schedule(interval)
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func schedule(_ ms: Int) {
        timer?.invalidate()
        interval = ms
        let t = Timer(timeInterval: Double(ms) / 1000, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func step() {
        guard let m = model else { return }
        let r = m.mascot.step(areaWidth: areaWidth, mouseOver: mouseOver, mouseX: mouseX)
        mascot = r
        if m.config.bool("showSky") && !(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && m.mascot.tick % 10 != 0) {
            sky = m.sky.step(width: skySize.width, height: skySize.height, weather: m.weatherProbe.weather,
                             place: m.weatherProbe.place(config: m.config))
        }
        // Reduce Motion: a calmer pace.
        let ms = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? r.intervalMs * 3 : r.intervalMs
        if ms != interval { schedule(ms) }
    }
}

/// The big percentage with the sky behind it and Clawd beside it.
struct TopRow: View {
    @ObservedObject var model: AppModel
    let anim: Animator
    let tracker: MouseTracker
    let pctColor: Color

    static let rowHeight: CGFloat = 40

    var body: some View {
        let showMascot = model.config.bool("showMascot")
        let showSky = showMascot && model.config.bool("showSky")
        HStack(alignment: .bottom, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(model.usage?.session.map(String.init) ?? "--")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(pctColor)
                Text("%").font(.system(size: 14)).foregroundColor(Color(hex: model.theme.muted))
            }
            .padding(.bottom, -3)
            if showMascot {
                GeometryReader { g in
                    MascotCanvas(anim: anim, model: model)
                        .frame(width: g.size.width, height: g.size.height + 3)
                        .offset(y: 0)
                        .onAppear { anim.areaWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in anim.areaWidth = w }
                }
                .padding(.leading, 10)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: Self.rowHeight)
        .contextMenu { if showMascot { DevMenu(model: model) } }
        .background(alignment: .topLeading) {
            if showSky {
                GeometryReader { g in
                    SkyLayer(anim: anim)
                        .frame(width: g.size.width, height: g.size.height + 3)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                                     .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                             startPoint: .leading, endPoint: .trailing))
                        .opacity(0.7)
                        .onAppear { anim.skySize = CGSize(width: g.size.width, height: g.size.height + 3) }
                        .onChange(of: g.size) { _, s in anim.skySize = CGSize(width: s.width, height: s.height + 3) }
                        .tip(model.sky.tooltip(weather: model.weatherProbe.weather, place: model.weatherProbe.place(config: model.config)))
                }
            }
        }
    }
}

/// Clawd and his effects, drawn from the engine's render.
struct MascotCanvas: View {
    @ObservedObject var anim: Animator
    let model: AppModel
    static let px = MascotEngine.px, py = MascotEngine.py
    static let mascotH = 12 * MascotEngine.py

    var body: some View {
        let r = anim.mascot
        GeometryReader { g in
            let H = g.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // The mascot's own canvas: left = r.x, bottom = r.bottom above the area's bottom.
                    let top = H - r.bottom - Self.mascotH
                    func rects(_ list: [PxRect], _ color: Color) {
                        var p = Path()
                        for q in list { p.addRect(CGRect(x: r.x + q.x * Self.px, y: top + q.y * Self.py, width: q.w * Self.px, height: q.h * Self.py)) }
                        ctx.fill(p, with: .color(color))
                    }
                    rects(r.geo.body, Color(hex: r.bodyColor))
                    rects(r.geo.eyes, Color(hex: r.eyeColor))
                    rects(r.geo.fx, Color(hex: "#6B7280"))
                    rects(r.geo.sand, Color(hex: "#B8955E"))
                    for a in r.geo.acc { rects(a.rects, Color(hex: a.color)) }
                    if let s = r.sweat {
                        ctx.fill(Path(CGRect(x: r.x + s.left, y: top + s.top, width: 3, height: 4.5)), with: .color(Color(hex: "#7DD3FC").opacity(s.opacity)))
                    }
                    for d in r.dust {
                        ctx.fill(Path(CGRect(x: d.x, y: H - d.bottom - 2, width: 2, height: 2)), with: .color(Color(hex: "#8B8B94").opacity(d.opacity)))
                    }
                    for c in r.confetti {
                        ctx.fill(Path(CGRect(x: c.x, y: H - c.bottom - 2.5, width: c.w, height: 2.5)), with: .color(Color(hex: c.color)))
                    }
                    if let l = r.love {
                        var p = Path()
                        let hp = 1.4
                        for q in MascotGeometry.heart(maxCol: 6) { p.addRect(CGRect(x: l.x + q.x * hp, y: H - l.bottom - 6 * hp + q.y * hp, width: hp, height: hp)) }
                        ctx.fill(p, with: .color(Color(hex: "#F87171").opacity(l.opacity)))
                    }
                    if let s = r.soul {
                        var p = Path()
                        let oy = H - s.bottomOfMouth
                        for q in s.rects { p.addRect(CGRect(x: s.x + q.x, y: oy + q.y, width: q.w, height: q.h)) }
                        ctx.fill(p, with: .color(Color(hex: "#F4F4F5").opacity(s.opacity)))
                    }
                }
                if let z = r.zzz {
                    Text("z").font(.system(size: z.size, weight: .semibold)).foregroundColor(Color(hex: model.theme.muted))
                        .opacity(z.opacity).fixedSize()
                        .position(x: z.x + z.size * 0.3, y: H - z.bottom - z.size * 0.6)
                }
                if let b = r.bubble {
                    Text(b.text).font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: b.color)).fixedSize()
                        .position(x: b.x + 6, y: H - b.bottom - 7)
                }
                if !r.tag.isEmpty {
                    Text(r.tag).font(.system(size: 8)).foregroundColor(Color(hex: "#6B7280")).fixedSize()
                        .position(x: 0, y: 5).offset(x: tagWidth(r.tag) / 2)
                }
                // The click target: Clawd himself.
                Color.clear.contentShape(Rectangle())
                    .frame(width: MascotEngine.width, height: Self.mascotH)
                    .offset(x: r.x, y: H - r.bottom - Self.mascotH)
                    .onTapGesture { model.mascot.click() }
            }
        }
    }

    func tagWidth(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 8)]).width
    }
}

struct SkyLayer: View {
    @ObservedObject var anim: Animator
    var body: some View { SkyCanvas(render: anim.sky) }
}

struct SkyCanvas: View {
    let render: SkyRender

    var body: some View {
        Canvas { ctx, size in
            let r = render
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [Color(rgba: r.top), Color(rgba: r.bottom)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            for s in r.stars {
                ctx.fill(Path(CGRect(x: s.x, y: s.y, width: 1.2, height: 1.2)), with: .color(Color(hex: "#F8FAFC").opacity(s.opacity)))
            }
            if let sun = r.sun {
                let glow = Path(ellipseIn: CGRect(x: sun.x - 10, y: sun.y - 10, width: 20, height: 20))
                ctx.fill(glow, with: .radialGradient(Gradient(colors: [Color(hex: "#40FDE68A"), Color(hex: "#00FDE68A")]),
                                                     center: CGPoint(x: sun.x, y: sun.y), startRadius: 0, endRadius: 10))
                pixels(ctx, SkyEngine.sunArt, px: SkyEngine.sunPx, x: sun.x - 4.9, y: sun.y - 4.9, color: Color(rgba: sun.color).opacity(sun.opacity))
            }
            if let m = r.moon {
                pixels(ctx, m.dark, px: SkyEngine.moonPx, x: m.x - 4.55, y: m.y - 4.55, color: Color(hex: "#2EE5E7EB").opacity(m.opacity))
                pixels(ctx, m.lit, px: SkyEngine.moonPx, x: m.x - 4.55, y: m.y - 4.55, color: Color(hex: "#F1F5F9").opacity(m.opacity))
            }
            for c in r.clouds {
                pixels(ctx, SkyEngine.cloudShapes[c.shape], px: 2, x: c.x, y: c.y, color: Color(rgba: r.cloudColor).opacity(c.opacity))
            }
            for f in r.fog {
                ctx.fill(Path(CGRect(x: f.x, y: f.y, width: f.w, height: 3)),
                         with: .linearGradient(Gradient(colors: [Color(hex: "#00E5E7EB"), Color(hex: "#E5E7EB").opacity(f.opacity), Color(hex: "#00E5E7EB")]),
                                               startPoint: CGPoint(x: f.x, y: 0), endPoint: CGPoint(x: f.x + f.w, y: 0)))
            }
            for d in r.drops { ctx.fill(Path(CGRect(x: d.x, y: d.y, width: 1, height: 3.5)), with: .color(Color(hex: "#8093C5FD"))) }
            for f in r.flakes { ctx.fill(Path(CGRect(x: f.x, y: f.y, width: 1.6, height: 1.6)), with: .color(Color(hex: "#C0E4E4E7"))) }
            if let g = r.ground { ctx.fill(Path(CGRect(x: 0, y: size.height - 1.5, width: size.width, height: 1.5)), with: .color(Color(rgba: g))) }
            if r.flash > 0 { ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: "#F8FAFC").opacity(r.flash))) }
        }
    }

    func pixels(_ ctx: GraphicsContext, _ rows: [String], px: Double, x: Double, y: Double, color: Color) {
        var p = Path()
        for (yy, row) in rows.enumerated() {
            for (xx, c) in row.enumerated() where c == "#" { p.addRect(CGRect(x: x + Double(xx) * px, y: y + Double(yy) * px, width: px, height: px)) }
        }
        ctx.fill(p, with: .color(color))
    }
}

/// Three hearts with halves in the header; they beat when health is low.
struct HeartsView: View {
    @ObservedObject var anim: Animator
    let theme: Theme

    var body: some View {
        if let h = anim.mascot.hearts {
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { i in
                    let v = h.show - 2 * i
                    Canvas { ctx, _ in
                        let hp = 1.4
                        var back = Path(), front = Path()
                        for q in MascotGeometry.heart(maxCol: 6) { back.addRect(CGRect(x: q.x * hp, y: q.y * hp, width: hp, height: hp)) }
                        if v >= 1 {
                            for q in MascotGeometry.heart(maxCol: v >= 2 ? 6 : 3) { front.addRect(CGRect(x: q.x * hp, y: q.y * hp, width: hp, height: hp)) }
                        }
                        ctx.fill(back, with: .color(Color(hex: theme.off)))
                        ctx.fill(front, with: .color(Color(hex: "#F87171")))
                    }
                    .frame(width: 7 * 1.4, height: 6 * 1.4)
                    .scaleEffect(h.beat)
                }
            }
            .tip(h.tip)
        }
    }
}
