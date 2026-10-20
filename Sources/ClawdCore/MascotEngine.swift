import Foundation

/// Health by number of heart halves: walking speed, tired eyes, yawns, sweat, swaying, stumbling.
public struct HealthTier {
    public var speed: Double
    public var hop = 0, yawn = 0, stumble = 0
    public var eyes: String?
    public var sweat = false, stagger = false

    public static let tiers: [Int: HealthTier] = [
        6: HealthTier(speed: 1.25, hop: 300),
        5: HealthTier(speed: 1.0),
        4: HealthTier(speed: 0.9, yawn: 350),
        3: HealthTier(speed: 0.75, yawn: 200, eyes: "focus"),
        2: HealthTier(speed: 0.55, yawn: 160, eyes: "focus", sweat: true),
        1: HealthTier(speed: 0.35, stumble: 220, eyes: "blink", sweat: true, stagger: true),
        0: HealthTier(speed: 0),
    ]
}

public enum Mood: String, CaseIterable { case sleep, doze, idle, work, wait, dead }

/// Heart halves 0..6 from the session percent: each half is ~16.7%; zero only at 100%.
public func heartHalves(_ pct: Int) -> Int {
    min(6, max(0, Int(ceil(Double(max(0, 100 - pct)) * 6 / 100))))
}

/// Mood checked top to bottom: dead, wait, work, idle, sleep.
public func moodFor(sessions: [Session], pct: Int?) -> Mood {
    if let pct, pct >= 100 { return .dead }
    if sessions.contains(where: \.waiting) { return .wait }
    if sessions.contains(where: \.busy) { return .work }
    if !sessions.isEmpty { return .idle }
    return .sleep
}

/// Everything the view needs to draw one frame (positions in points inside the mascot area).
public struct MascotRender {
    public var geo = MascotGeo()
    public var x = 0.0                // left edge of Clawd
    public var bottom = 0.0           // lift above the ground
    public var zzz: (x: Double, bottom: Double, size: Double, opacity: Double)?
    public var bubble: (text: String, color: String, x: Double, bottom: Double)?
    public var sweat: (left: Double, top: Double, opacity: Double)?
    public var dust: [(x: Double, bottom: Double, opacity: Double)] = []
    public var confetti: [(x: Double, bottom: Double, w: Double, color: String)] = []
    public var love: (x: Double, bottom: Double, opacity: Double)?
    public var soul: (rects: [PxRect], x: Double, bottomOfMouth: Double, opacity: Double)?
    public var tag = ""
    public var hearts: (show: Int, beat: Double, tip: String)?
    public var intervalMs = 90
    public var bodyColor = Skin.classic.body
    public var eyeColor = Skin.classic.eyes
    public init() {}
}

/// The mascot's state machine, a port of lib/mascot.ps1 + mascot-step.ps1 + hearts.ps1.
public final class MascotEngine {
    public static let px = 2.0, py = 2.2
    public static let width = Double(MascotGeometry.W) * px     // 36
    public static let sink = 2 * py                               // the empty lower half-row of the legs
    public static let frameMs = 60
    public static let drainStep = 22
    public static var drainLen: Int { 6 * drainStep + 35 }
    static let soulUp = 26, soulBack = 48
    static let soulTop = 20.0
    static let confettiColors = ["#F87171", "#FBBF24", "#4ADE80", "#60A5FA", "#A78BFA", "#D77757"]

    public var skin = Skin.classic { didSet { if skin != oldValue { MascotGeometry.clearCache() } } }

    // State (upstream $script:Mz).
    public var x = -1.0
    var dir = 1.0
    var target: Double?
    var look = 0
    public private(set) var tick = 0
    var blinkAt = 30
    public private(set) var mood: Mood = .idle
    var cur: Mood = .idle
    var crit = false
    public var idleSince = Date()
    public private(set) var act: String?
    var actT = 0
    public var force: Mood?
    public var forceCrit = false
    public private(set) var demo = -1
    var demoT = 0
    var pct: Int?
    var halves: Int?
    var lostT = -1, lostFrom = 0
    public var forceHearts: Int?
    var drainT = -1, loveT = -1, noteT = -1, confT = -1
    var busy = -1, waiting = 0
    var lastReset: Date?
    var lastPct: Int?
    var buried = false
    var confetti: [(x: Double, y: Double, v: Double, d: Double)] = []
    private var rng = SystemRandomNumberGenerator()

    public init() {
        if let e = MascotData.shared.entranceActs.randomElement() { startAct(e) }
    }

    func rnd(_ n: Int) -> Int { n <= 0 ? 0 : Int.random(in: 0..<n, using: &rng) }
    func rndD() -> Double { Double.random(in: 0..<1, using: &rng) }

    public var isDev: Bool { demo >= 0 || force != nil || forceCrit || forceHearts != nil }

    public func startAct(_ name: String) {
        act = name; actT = 0
        if name == "celebrate" { startConfetti() }
    }

    func startConfetti() {
        confetti = (0..<12).map { _ in
            (x - 12 + rndD() * (Self.width + 24), 34 + rndD() * 12, 0.9 + rndD() * 1.2, (rndD() - 0.5) * 0.8)
        }
        confT = 0
    }

    /// Click: a random Claude Code animation and a heart; lying dead - the soul leaves the body.
    public func click() {
        idleSince = Date()
        if mood == .dead || cur == .dead { if act == nil { startAct("soul") }; return }
        loveT = 0
        if buried && cur == .sleep { if act == nil { startAct("stir") }; return }
        if act != nil { return }
        if let a = MascotData.shared.clickActs.randomElement() { startAct(a) }
    }

    /// Fed every refresh tick with the live sessions and limits.
    public func setMood(sessions: [Session], usage: Usage?, critPercent: Double) {
        let b = sessions.filter(\.busy).count
        let w = sessions.filter(\.waiting).count
        let p = usage?.session
        let m = moodFor(sessions: sessions, pct: p)
        if m != mood { idleSince = Date() }
        mood = m
        // A session finished its reply (rather than stopping to wait for us) - jump.
        if busy > 0 && b < busy && w <= waiting && act == nil { startAct("jump") }
        busy = b; waiting = w
        crit = p.map { Double($0) >= critPercent } ?? false
        pct = p
        // The 5-hour window reset: reset time moved forward and the percent dropped - celebrate.
        if let u = usage, let r = u.sessionReset {
            if let lr = lastReset, r > lr, let lp = lastPct, let p, p < lp { startAct("celebrate") }
            lastReset = r; lastPct = p
        }
    }

    // Developer mode.
    public func setForce(_ m: Mood?) { stopDemo(); force = m; act = nil }
    public func setForceCrit(_ on: Bool) { forceCrit = on }
    public func play(_ a: String) { if force == nil { force = .idle }; target = nil; startAct(a) }
    public func backToAuto() { stopDemo(); force = nil; forceCrit = false; forceHearts = nil; act = nil }

    public static var demoSteps: [(kind: String, id: String)] {
        var s: [(String, String)] = [("mood", "sleep"), ("mood", "doze"), ("mood", "idle"), ("mood", "work"),
                                     ("crit", "work"), ("mood", "wait"), ("drain", "idle")]
        for a in MascotData.shared.actOrder where !MascotData.shared.noDemo.contains(a) { s.append(("act", a)) }
        return s
    }

    public func startDrain() { stopDemo(); drainT = 0 }

    public func startDemo() { stopDemo(); demo = 0; demoT = 0 }

    func stopDemo() {
        demo = -1; demoT = 0; force = nil; forceCrit = false; act = nil
        if drainT >= 0 { drainT = -1; forceHearts = nil }
    }

    func stepDemo() {
        let steps = Self.demoSteps
        let s = steps[demo]
        if demoT == 0 {
            forceCrit = false
            switch s.kind {
            case "mood": force = Mood(rawValue: s.id); act = nil
            case "crit": force = Mood(rawValue: s.id); act = nil; forceCrit = true
            case "act": force = .idle; target = nil; startAct(s.id)
            default: force = .work; act = nil; drainT = 0
            }
        }
        demoT += 1
        let len: Int
        switch s.kind {
        case "act": len = (MascotData.shared.actLen[s.id] ?? 20) + 12
        case "drain": len = Self.drainLen + 10
        default: len = 55
        }
        if demoT >= len {
            demoT = 0; demo += 1
            if demo >= steps.count { stopDemo() }
        }
    }

    func currentHalves() -> Int? {
        var h: Int?
        if let f = forceHearts { h = f }
        else if force == .dead { h = 0 }
        else if let p = pct { h = heartHalves(p) }
        return h.map { min(6, max(0, $0)) }
    }

    /// One animation step. `areaWidth`: width of the mascot area; `mouseX`: cursor x in the area, nil when outside the window.
    public func step(areaWidth: Double, mouseOver: Bool, mouseX: Double?, now: Date = Date()) -> MascotRender {
        tick += 1
        let span = max(0, areaWidth - Self.width)
        if x < 0 { x = span / 2 }
        if x > span { x = span }
        if let t = target, t > span { target = span }

        if demo >= 0 { stepDemo() }
        if drainT >= 0 {
            forceHearts = max(0, 6 - drainT / Self.drainStep)
            drainT += 1
            if drainT >= Self.drainLen { drainT = -1; forceHearts = nil }
        }
        var md = force ?? mood
        if let fh = forceHearts, fh == 0 { md = .dead }
        let hv = currentHalves()
        let tierN = hv ?? 5
        let tier = HealthTier.tiers[tierN] ?? HealthTier.tiers[5]!
        let perky = tier.speed >= 0.9
        if mouseOver { idleSince = now }
        if md == .idle && force == nil && now.timeIntervalSince(idleSince) >= 600 { md = .doze }

        // Falling asleep - burrows in once the current animation ends; waking - climbs out at once.
        if md == .sleep {
            if !buried && act == nil { buried = true; startAct("burrow") }
        } else if buried {
            buried = false; startAct("unburrow")
        }

        var f = ClawdFrame()
        f.look = look
        if cur == .work && md != .work { target = nil }
        cur = md
        var bubble = "", zzz = false, canBlink = true, dust = false

        let mouseLook: Int? = {
            guard mouseOver, let mx = mouseX else { return nil }
            let cx = x + Self.width / 2
            if mx > cx + 10 { return 1 }
            if mx < cx - 10 { return -1 }
            return 0
        }()

        if act != nil {
            bubble = stepAct(&f)
            canBlink = false
        } else {
            switch md {
            case .sleep:
                f.dig = MascotGeometry.burrowDig; f.eyes = "closed"; f.look = 0; zzz = true
            case .doze:
                f.look = 0
                let p = tick % 70
                if p < 6 { f.eyes = "wide"; if p < 2 { f.lift = 1.5 } } else { f.eyes = "blink"; zzz = true }
            case .dead:
                f.flip = true; f.eyes = "x"; f.look = 0
                let p = tick % 50
                if p < 6 { f.feet = p % 2 == 1 ? "left" : "right" }
            case .wait:
                bubble = "?"; f.eyes = "wide"
                f.look = mouseLook ?? 0
                let p = tick % 40
                if p < 8 { let k = Double(p) / 7; f.lift = 12 * k * (1 - k); f.arms = "right" }
            default:
                let speed: Double
                if md == .work {
                    speed = 1.6 * tier.speed
                    if target == nil { target = dir > 0 ? span : 0 }
                } else {
                    speed = 0.6 * tier.speed
                    if target == nil {
                        if rnd(70) == 0 { target = rndD() * span }
                        else if rnd(45) == 0 { look = rnd(3) - 1 }
                        else if rnd(400) == 0 { startAct(["wave", "stretch", "look"][rnd(3)]) }
                    }
                }
                var walking = false
                if let t = target {
                    let d = t - x
                    if abs(d) <= speed {
                        x = t; target = nil
                        if md == .work { dir = -dir }
                    } else {
                        dir = d > 0 ? 1 : -1
                        x += speed * dir
                        look = Int(dir)
                        walking = true
                    }
                }
                if walking {
                    var stepN = md == .work ? 2 : 3
                    if tier.speed < 0.8 { stepN += 1 }
                    if tier.speed < 0.5 { stepN += 1 }
                    f.feet = (tick / stepN) % 2 == 1 ? "left" : "right"
                    if md == .work {
                        if f.feet == "left" && perky { f.lift = 1 }
                        dust = true
                        if perky && rnd(150) == 0 { startAct("jump") }
                    } else if perky && noteT < 0 && rnd(80) == 0 {
                        noteT = 0
                    }
                    if tier.stumble > 0 && rnd(tier.stumble) == 0 { startAct("stumble") }
                } else if crit || forceCrit {
                    look = (tick / 5) % 2 == 1 ? -1 : 1
                } else if let ml = mouseLook {
                    look = ml
                }
                f.look = look
                if md == .work { f.eyes = "focus" }
                if act == nil {
                    if tier.hop > 0 && rnd(tier.hop) == 0 { startAct("jump") }
                    if tier.yawn > 0 && rnd(tier.yawn) == 0 { startAct("yawn") }
                }
            }
        }

        if let e = tier.eyes, act == nil, f.eyes == "open" || f.eyes == "focus" { f.eyes = e }
        if loveT >= 0 && act == nil && f.eyes == "open" { f.eyes = "happy" }
        if noteT >= 0 {
            if bubble.isEmpty && md == .idle { bubble = "♪" }
            noteT += 1
            if noteT >= 30 { noteT = -1 }
        }
        if canBlink && f.eyes == "open" && tick >= blinkAt {
            f.eyes = "blink"
            if tick >= blinkAt + 1 { blinkAt = tick + 25 + rnd(45) }
        }

        var r = MascotRender()
        r.bodyColor = skin.body; r.eyeColor = skin.eyes
        r.geo = MascotGeometry.build(f, skin: skin)
        r.intervalMs = (act.map { MascotData.shared.seqs[$0] != nil } ?? false) ? Self.frameMs : 90
        var rx = x
        if tier.stagger && md != .sleep && md != .dead { rx += 1.5 * sin(Double(tick) / 3) }
        r.x = rx.rounded()
        r.bottom = f.lift - Self.sink

        if zzz {
            let p = Double(tick % 30) / 30
            let zb: Double = f.dig > 0 ? 9 : f.off > 0 ? 12 : 19
            r.zzz = (x + 28 + 3 * sin(p * 2 * .pi), zb + 14 * p, 7 + 4 * p, 1 - p)
        }
        if !bubble.isEmpty {
            let color = bubble == "?" ? Palette.warn : bubble == "!" ? Palette.ok : "#93C5FD"
            r.bubble = (bubble, color, x + Self.width / 2 - 6, 22 + f.lift + 1.5 * sin(Double(tick) / 3))
        }
        if (crit || forceCrit || tier.sweat) && md != .sleep && md != .dead {
            let p = Double(tick % 20) / 20
            r.sweat = (f.look < 0 ? 31 : 2, -2 + 6 * p - f.lift, 1 - p)
        }
        r.hearts = stepHearts(hv, tierN: tierN)
        if dust {
            for i in 0..<3 {
                let p = Double((tick + i * 3) % 9) / 9
                let dx = dir > 0 ? 4 - 8 * p - 2 * Double(i) : Self.width - 6 + 8 * p + 2 * Double(i)
                r.dust.append((x + dx, 4 * p, 0.7 * (1 - p)))
            }
        }
        if confT >= 0 {
            for i in confetti.indices {
                confetti[i].y -= confetti[i].v; confetti[i].x += confetti[i].d
                if confetti[i].y > 0 {
                    r.confetti.append((confetti[i].x, confetti[i].y, ((tick + i) / 2) % 2 == 1 ? 2.5 : 1.2,
                                       Self.confettiColors[i % Self.confettiColors.count]))
                }
            }
            confT += 1
            if confT >= 45 { confT = -1 }
        }
        if loveT >= 0 {
            let k = Double(loveT) / 20
            r.love = (x + Self.width / 2 - 5 + 2 * sin(k * 6), 23 + f.lift + 14 * k, 1 - k)
            loveT += 1
            if loveT >= 20 { loveT = -1 }
        }
        if f.soul > 0.5 {
            r.soul = (MascotGeometry.soul(height: f.soul, t: f.soulT), x + 9.5 * Self.px, f.lift + 6 * Self.py,
                      0.7 + 0.15 * sin(Double(f.soulT) / 1.7))
        }
        if isDev {
            var tag: String
            if drainT >= 0 { tag = md == .dead ? T("mood.dead") : T("health.\(tierN)") }
            else if let a = act { tag = T("act.\(a)") }
            else if forceCrit { tag = T("tag.sweat") }
            else { tag = T("mood.\(md.rawValue)") }
            if forceHearts != nil && drainT < 0 && md != .dead { tag += " · \(T("health.\(tierN)"))" }
            r.tag = demo >= 0 ? T("tag.demo", demo + 1, Self.demoSteps.count, tag) : "dev · \(tag)"
        }
        return r
    }

    func stepHearts(_ hv: Int?, tierN: Int) -> (show: Int, beat: Double, tip: String)? {
        guard let hv else { halves = nil; return nil }
        var tip = T("health.\(hv)")
        if let p = pct, forceHearts == nil { tip = T("hearts.left", tip, 100 - p) }
        // Lost a heart - the lost part blinks for a couple of seconds.
        if let h = halves, hv < h { lostT = 0; lostFrom = h }
        halves = hv
        var show = hv
        if lostT >= 0 {
            if lostT % 4 < 2 { show = lostFrom }
            lostT += 1
            if lostT >= 16 { lostT = -1 }
        }
        var beat = 1.0
        if hv > 0 && hv <= 2 {
            let p = tick % 12
            if p == 0 { beat = 1.3 } else if p == 1 { beat = 1.15 }
        }
        return (show, beat, tip)
    }

    /// One frame of a one-shot animation; returns the bubble text.
    func stepAct(_ f: inout ClawdFrame) -> String {
        guard let a = act else { return "" }
        let t = actT
        var bubble = ""
        let d = MascotData.shared
        if let seq = d.seqs[a], t < seq.count {
            let fr = seq[t]
            f.eyes = fr.eyes; f.arms = fr.arms; f.feet = fr.feet; f.off = fr.off; f.x = fr.x
            f.facing = fr.facing; f.poof = fr.poof; f.shadow = fr.shadow
            f.look = 0
            if a == "celebrate" { bubble = "!" }
        } else {
            let dig = MascotGeometry.burrowDig
            switch a {
            case "wave":
                f.look = 0; f.eyes = "happy"; f.arms = (t / 4) % 2 == 1 ? "down" : "right"
            case "stretch":
                if t >= 4 && t < 18 { f.arms = "up"; f.eyes = "closed"; f.lift = 1.5 }
            case "yawn":
                f.look = 0; f.eyes = t >= 3 && t < 17 ? "yawn" : "closed"
            case "stumble":
                if t < 12 { f.off = 1; f.eyes = "closed" } else { f.eyes = "wide" }
                f.look = 0
            case "soul":
                f.flip = true; f.look = 0
                if t < 6 { f.eyes = "x"; f.feet = t % 2 == 1 ? "left" : "right" }
                else if t < Self.soulBack + 6 {
                    f.eyes = "gasp"; f.soulT = t
                    if t < Self.soulUp {
                        let k = Double(t - 6) / Double(Self.soulUp - 6)
                        f.soul = Self.soulTop * (1 - (1 - k) * (1 - k))
                    } else if t < Self.soulBack {
                        f.soul = Self.soulTop + 1.5 * sin(Double(t - Self.soulUp) / 2.5)
                    } else {
                        let k = Double(t - Self.soulBack) / 6
                        f.soul = Self.soulTop * (1 - k * k)
                    }
                } else if t < Self.soulBack + 9 { f.eyes = "wide"; f.lift = 2.5 }
                else { f.eyes = "x" }
            case "burrow":
                if t < 4 { f.look = t < 2 ? -1 : 1 }
                else if t < 24 {
                    f.look = 0; f.eyes = "focus"
                    f.dig = min(dig, Int(floor(Double(t - 4) / 3.5)))
                    f.feet = (t / 2) % 2 == 1 ? "left" : "right"
                    f.arms = (t / 2) % 2 == 1 ? "up" : "down"
                    f.spray = t % 3 + 1
                } else { f.look = 0; f.dig = dig; f.eyes = t < 27 ? "blink" : "closed" }
            case "unburrow":
                f.look = 0
                if t < 3 { f.dig = dig; f.eyes = "wide" }
                else if t < 9 {
                    f.dig = max(0, dig - (t - 3)); f.eyes = "wide"; f.arms = "up"; f.spray = t % 3 + 1
                    if t == 8 { f.lift = 2 }
                } else if t < 21 {
                    f.eyes = "closed"
                    f.look = (t / 2) % 2 == 1 ? -1 : 1
                    f.feet = (t / 2) % 2 == 1 ? "left" : "right"
                    if t < 15 { f.spray = t % 3 + 1 }
                } else if t < 23 { f.eyes = "blink" }
            case "stir":
                f.dig = t < 15 ? dig - 1 : dig
                if t < 3 { f.eyes = "wide"; f.look = 0 }
                else if t < 13 { f.look = t < 8 ? -1 : 1 }
                else if t < 17 { f.eyes = "blink"; f.look = 0 }
                else { f.eyes = "closed"; f.look = 0 }
            default: break
            }
        }
        actT += 1
        if actT >= (d.actLen[a] ?? 1) { act = nil }
        return bubble
    }
}
