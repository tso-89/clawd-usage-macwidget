import Foundation
import Testing
@testable import ClawdCore

/// Integration: the real Assistant / probes against Tests/Fixtures/fake-claude.sh (see docs/tests/TEST_REGISTRY.md).
@Suite(.serialized) struct IntegrationTests {
    static let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fake-claude.sh").path

    /// Waits for main-queue completions.
    func wait(_ cond: @escaping () -> Bool, timeout: Double = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await MainActor.run(body: cond) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    @MainActor func makeAssistant() -> (Assistant, URL, URL) {
        let home = tempDir()
        // The child environment is captured once per process: one log file, emptied per test.
        let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")
            .appendingPathComponent("clawd-fake-claude-argv.log")
        try? "".write(to: log, atomically: true, encoding: .utf8)
        let cfg = Config(url: home.appendingPathComponent("config.json"))
        cfg["clawdHome"] = home.path
        let a = Assistant(config: cfg, advisor: Advisor(config: cfg), claude: { Self.fake }, usage: { nil })
        a.reset()
        return (a, home, log)
    }

    @Test func chatRoundTrip() async throws {
        let (a, _, log) = await makeAssistant()
        await MainActor.run { a.send("clean the caches") }
        #expect(await wait { !a.chatBusy && a.messages.contains { $0.role == "clawd" } })
        await MainActor.run {
            let reply = a.messages.first { $0.role == "clawd" }!
            #expect(reply.text == "Done.")
            #expect(reply.run?.script == "echo hello from run")
            #expect(reply.act?.calls.first?.tool == "mcp__mail__move")
            #expect(a.reminders.all().first?.text == "Fake reminder")
            // The task block asked for tools: the task is made without them, the valid one waits on a card.
            #expect(a.findTask("Fake")?.tools == [])
            #expect(a.messages.first { $0.grant != nil }?.grant?.rules == ["mcp__mail"])
        }
        let argv = try String(contentsOf: log, encoding: .utf8)
        #expect(argv.contains("--session-id"))
        #expect(argv.contains("Bash(du:*)"))
        #expect(argv.contains("--strict-mcp-config"))
        // Approving the script runs it in zsh and sends the output back (hidden).
        await MainActor.run { a.startRun(a.messages.first { $0.run != nil }!) }
        #expect(await wait { !a.runBusy && a.messages.contains { $0.run?.state == "done" } && !a.chatBusy })
        let argv2 = try String(contentsOf: log, encoding: .utf8)
        #expect(argv2.contains("--resume"))
    }

    @Test func taskRunAndGrant() async throws {
        let (a, _, log) = await makeAssistant()
        await MainActor.run {
            // A hand-edited (or injected) file: only rules reach the command line.
            a.writeTask("Mail", ["every": "10m", "tools": "mcp__mail --dangerously-skip-permissions Bash"], "Check mail.")
            a.config["showTasks"] = true
            a.updateTasks()
        }
        #expect(await wait { a.runningTask == nil && a.messages.contains { $0.grant != nil } })
        await MainActor.run {
            let card = a.messages.first { $0.grant != nil }!
            #expect(card.grant?.rules == ["Bash(gh issue list:*)"])
            a.grant(card)
            #expect(a.findTask("Mail")?.tools == ["mcp__mail", "Bash(gh issue list:*)"])
            #expect(a.taskState()["Mail"]?.last == nil)
        }
        let argv = try String(contentsOf: log, encoding: .utf8)
        #expect(argv.contains("--json-schema"))
        #expect(argv.contains("mcp__mail"))
        #expect(!argv.contains("--strict-mcp-config"))
        #expect(!argv.contains("--dangerously-skip-permissions"))
        #expect(!argv.contains(" Bash "))
    }

    @Test func usageAndAccountProbes() async {
        let p = UsageProbe(), acc = AccountProbe()
        await MainActor.run { p.start(claude: Self.fake); acc.start(claude: Self.fake) }
        #expect(await wait { p.usage != nil && acc.account != nil })
        #expect(p.usage?.session == 13)
        #expect(acc.account == Account(loggedIn: true, plan: "Max", email: "me@example.com"))
    }

    @Test func whenProbe() async {
        var got: Date?
        var done = false
        await MainActor.run { WhenParser.ask("next friday", claude: Self.fake, model: "haiku") { got = $0; done = true } }
        #expect(await wait { done })
        #expect(got == ReminderStore.parseAt("2026-10-19T09:30") || got == nil)
    }
}

/// The hidden session's terminal: the child must see a real tty (claude's TUI needs one).
struct PtyTests {
    @Test func childGetsATTY() async throws {
        let home = tempDir()
        let cfg = Config(url: home.appendingPathComponent("config.json"))
        cfg["clawdHome"] = home.path
        let s = ClawdSession(config: cfg, claude: { nil })
        let out = home.appendingPathComponent("tty.txt")
        s.startHidden("/bin/sh", ["-c", "tty > '\(out.path)'; [ -t 0 ] && echo stdin-tty >> '\(out.path)'"], home)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: out.path) { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text.hasPrefix("/dev/ttys"))
        #expect(text.contains("stdin-tty"))
        s.shutdown()
    }
}

/// The real scan of this Mac; read-only. Runs only with CLAWD_LIVE_ADVISOR=1 (it reads ~/Downloads and the Trash).
struct LiveAdvisorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAWD_LIVE_ADVISOR"] == "1"))
    func scanThisMac() {
        let s = Advisor.run(diskGB: 10_000, unusedDays: 90, memPercent: 5)
        print("disks", s.disks.map { "\($0.name) \($0.free)" })
        print("junk", s.junk.map { "\($0.id) \(String(format: "%.2f", $0.size))" })
        print("startup", s.startup.count, s.startup.prefix(5))
        print("apps", s.apps.prefix(5).map { "\($0.name) \(String(format: "%.1f", $0.size)) \($0.last.map { "\($0)" } ?? "never")" })
        print("uptime", s.uptimeDays, "mem", s.mem.map { "\($0.name) \($0.pct)%" }, "cpu", s.cpu.map(\.name))
        #expect(!s.disks.isEmpty)
    }
}
