import Foundation
import Testing
@testable import ClawdCore

func fixture(_ name: String) -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

struct UsageParserTests {
    let now = date(2026, 10, 17, 21, 0)

    @Test func parsesCurrentFormatWithAt() throws {
        let u = try #require(UsageParser.parse(fixture("usage-real.txt"), now: now))
        #expect(u.session == 13)
        #expect(u.week == 48)
        #expect(u.fable == 0)
        #expect(u.sessionReset == date(2026, 10, 18, 0, 50))
        #expect(u.weekReset == date(2026, 10, 19, 0, 0))
        #expect(u.day?.requests == 746)
        #expect(u.day?.sessions == 17)
        #expect(u.week7?.requests == 13962)
        #expect(u.day?.lines.count == 7)
    }

    @Test func parsesOldCommaFormatAndHourOnly() throws {
        let u = try #require(UsageParser.parse(fixture("usage-old.txt"), now: now))
        #expect(u.sessionReset == date(2026, 10, 17, 5, 19))
        #expect(u.weekReset == date(2026, 10, 19, 6, 0))
        #expect(u.fable == 19)
        #expect(u.week7?.lines.last == "Some brand new metric line")
    }

    @Test func noResetsMeansZeroAndSingulars() throws {
        let u = try #require(UsageParser.parse(fixture("usage-zero.txt"), now: now))
        #expect(u.session == 0)
        #expect(u.sessionReset == nil)
        #expect(u.fable == nil)
        #expect(u.day?.requests == 1)
        #expect(u.day?.sessions == 1)
    }

    @Test func newYearRollover() {
        let d = UsageParser.parseResetStamp("Jan 2, 1:00am", now: date(2026, 12, 31, 22))
        #expect(d == date(2027, 1, 2, 1, 0))
    }

    @Test func noonAndMidnight() {
        #expect(UsageParser.parseResetStamp("Oct 19 at 12pm", now: now) == date(2026, 10, 19, 12, 0))
        #expect(UsageParser.parseResetStamp("Oct 19 at 12am", now: now) == date(2026, 10, 19, 0, 0))
    }

    @Test func garbageIsNil() {
        #expect(UsageParser.parse("Please run /login") == nil)
    }

}

/// Tests that read or switch the global UI language run one at a time.
@Suite(.serialized) struct LanguageTests {
    @Test func statLinesTranslatedUnknownKept() {
        I18n.lang = "en"
        #expect(UsageParser.formatStatLine("73% of your usage was at >150k context") == "73% at >150k context")
        #expect(UsageParser.formatStatLine("Something new") == "Something new")
    }
}

struct SessionTests {
    @Test func procStartFormats() {
        let d = Sessions.parseProcStart("Sun Oct 18 04:39:16 2026")
        #expect(d == ISO8601DateFormatter().date(from: "2026-10-18T04:39:16Z"))
        #expect(Sessions.parseProcStart("134366656907618771") != nil)
        #expect(Sessions.parseProcStart("garbage") == nil)
    }

    @Test func liveFilteringAndReusedPID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let start = ISO8601DateFormatter().date(from: "2026-10-18T04:39:16Z")!
        func write(_ pid: Int, _ status: String, _ proc: String, name: String = "") throws {
            let j = "{\"pid\":\(pid),\"cwd\":\"/x/proj\(pid)\",\"status\":\"\(status)\",\"procStart\":\"\(proc)\",\"name\":\"\(name)\",\"sessionId\":\"s\(pid)\"}"
            try j.write(to: dir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        }
        try write(1, "busy", "Sun Oct 18 04:39:16 2026", name: "alpha")
        try write(2, "waiting", "Sun Oct 18 04:39:16 2026")
        try write(3, "idle", "Sun Oct 18 05:00:00 2026")   // pid reused
        try write(4, "idle", "Sun Oct 18 04:39:16 2026")   // dead
        let list = Sessions.local(dir: dir) { pid in pid == 4 ? nil : start }
        #expect(list.map(\.pid).sorted() == [1, 2])
        #expect(list.first { $0.pid == 1 }?.name == "alpha")
        #expect(list.first { $0.pid == 2 }?.name == "proj2")
        #expect(list.first { $0.pid == 2 }?.waiting == true)
    }

    @Test func remoteFeedStaleAndHost() {
        let fresh = Data("{\"generatedAt\":\"2026-10-17T03:41:47+00:00\",\"host\":\"unraid\",\"sessions\":[{\"name\":\"api\",\"status\":\"busy\",\"sessionId\":\"4b8c\"}]}".utf8)
        let now = ISO8601DateFormatter().date(from: "2026-10-17T03:42:30Z")!
        let s = RemoteSessions.parse(fresh, now: now)
        #expect(s.count == 1 && s[0].host == "unraid" && s[0].busy)
        #expect(RemoteSessions.parse(fresh, now: now.addingTimeInterval(600)).isEmpty)
    }
}

extension LanguageTests {
    @Test func netFormat() {
        #expect(NetFormat.format("{0}h {1:00}m", [3, 3]) == "3h 03m")
        #expect(NetFormat.format("{{x}} {0}", ["a"]) == "{x} a")
    }

    @Test func spans() {
        I18n.lang = "en"
        let now = Date()
        #expect(Fmt.span(to: now.addingTimeInterval(3 * 3600 + 3 * 60 + 5), now: now) == "3h 03m")
        #expect(Fmt.span(to: now.addingTimeInterval(26 * 3600 + 10), now: now) == "1d 2h")
        #expect(Fmt.span(to: now.addingTimeInterval(-5), now: now) == nil)
    }

    @Test func plurals() {
        I18n.lang = "ru"
        #expect(formatCount(1, "session").hasPrefix("1 "))
        #expect(formatCount(22, "session") != formatCount(25, "session"))
        I18n.lang = "en"
        #expect(formatCount(1, "session") == "1 session")
        #expect(formatCount(5, "session") == "5 sessions")
    }

    @Test func semver() {
        #expect(SemVer("2.1.302")! > SemVer("2.1.300")!)
        #expect(SemVer("v1.10.0")! > SemVer("1.9.9")!)
    }
}
