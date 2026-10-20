import Foundation
import Testing
@testable import ClawdCore

struct MascotTests {
    @Test func halvesFormula() {
        #expect(heartHalves(0) == 6)
        #expect(heartHalves(17) == 5)
        #expect(heartHalves(99) == 1)
        #expect(heartHalves(100) == 0)
        #expect(heartHalves(150) == 0)
    }

    @Test func moodPriority() {
        let busy = Session(name: "a", busy: true), wait = Session(name: "b", waiting: true), idle = Session(name: "c")
        #expect(moodFor(sessions: [busy, wait], pct: 100) == .dead)
        #expect(moodFor(sessions: [busy, wait], pct: 50) == .wait)
        #expect(moodFor(sessions: [busy, idle], pct: 50) == .work)
        #expect(moodFor(sessions: [idle], pct: nil) == .idle)
        #expect(moodFor(sessions: [], pct: 10) == .sleep)
    }

    @Test func dataLoaded() {
        let d = MascotData.shared
        #expect(d.seqs.count == 15)
        #expect(d.clickActs.contains("wink"))
        #expect(d.actLen["soul"] == 66)
    }

    @Test func defaultPoseGeometry() {
        let g = MascotGeometry.build(ClawdFrame(), skin: .classic)
        #expect(!g.body.isEmpty)
        #expect(!g.eyes.isEmpty)
        // Everything within the 18x12 frame.
        #expect(g.body.allSatisfy { $0.x >= 0 && $0.x + $0.w <= 18 && $0.y >= 0 && $0.y < 12 })
    }

    @Test func finishedSessionJumpsAndResetCelebrates() {
        let m = MascotEngine()
        while m.act != nil { _ = m.step(areaWidth: 150, mouseOver: false, mouseX: nil) }
        var u = Usage(); u.session = 50; u.sessionReset = Date().addingTimeInterval(3600)
        m.setMood(sessions: [Session(name: "a", busy: true)], usage: u, critPercent: 85)
        m.setMood(sessions: [Session(name: "a")], usage: u, critPercent: 85)
        #expect(m.act == "jump")
        while m.act != nil { _ = m.step(areaWidth: 150, mouseOver: false, mouseX: nil) }
        var u2 = Usage(); u2.session = 2; u2.sessionReset = Date().addingTimeInterval(5 * 3600)
        m.setMood(sessions: [Session(name: "a")], usage: u2, critPercent: 85)
        #expect(m.act == "celebrate")
    }

    @Test func demoRunsThrough() {
        let m = MascotEngine()
        m.startDemo()
        var n = 0
        while m.demo >= 0 && n < 20000 { _ = m.step(areaWidth: 150, mouseOver: false, mouseX: nil); n += 1 }
        #expect(m.demo == -1)
    }

    @Test func skinParse() throws {
        let s = try #require(Skins.parse("---\nname: Top hat\nk: #4B5563\nr: #DC2626\n---\n..kk\n..rr\n", id: "tophat"))
        #expect(s.name == "Top hat")
        #expect(s.layers.count == 2)
        #expect(s.layers[0].px.first == [2, -2])
        let shades = try #require(Skins.parse("---\ntop: 1\ns: #111827\n---\n...s\n", id: "shades"))
        #expect(shades.layers[0].px == [[3, 1]])
        #expect(Skins.parse("no front matter", id: "x") == nil)
    }

    @Test func bundledSkinsLoad() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Paths.resource("skins"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
        let ids = Set(Skins.all(home: URL(fileURLWithPath: "/nonexistent")).map(\.id))
        #expect(files.count >= 17)
        for f in files { #expect(ids.contains(f.deletingPathExtension().lastPathComponent)) }
    }
}
