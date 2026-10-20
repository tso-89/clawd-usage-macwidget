import Foundation
import Darwin

/// Clawd's own interactive Claude Code session in his home, with Remote Control under the
/// widget's name, kept running by the widget (upstream lib/clawd-session.ps1).
///
/// Hidden mode: `claude` runs on a pseudo-terminal owned by the app (it is an interactive TUI and
/// needs a tty); the output is drained and dropped. It lives as long as the app does and comes
/// back to its conversation (--resume) on the next start. Visible mode (or a folder Claude Code
/// has not trusted yet): a Terminal window, through a .command file.
public final class ClawdSession {
    let config: Config
    var launched = Date.distantPast
    var misses = 0
    /// Remote Control lost after a resume: 1 - next start forks, 2 - fresh conversation, 3 - give up.
    var rcRetry = 0
    var child: pid_t = 0
    var master: Int32 = -1
    var drain: DispatchSourceRead?
    var statePath: URL { config.dataFile("clawd-state.json") }
    public var claude: () -> String?

    public init(config: Config, claude: @escaping () -> String?) {
        self.config = config
        self.claude = claude
    }

    public var name: String {
        let n = config.string("clawdSessionName").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "clawd-usage-macwidget" : n
    }

    public var sessionId: String { (JSONFile.readObject(statePath)?["sessionId"] as? String) ?? "" }
    func setSessionId(_ id: String) { if id != sessionId { JSONFile.write(["sessionId": id], to: statePath) } }

    static func samePath(_ a: String, _ b: String) -> Bool {
        let t = CharacterSet(charactersIn: "/")
        return a.trimmingCharacters(in: t) == b.trimmingCharacters(in: t)
    }

    /// A folder Claude Code has not trusted asks about it in the terminal - a hidden one would wait forever.
    public func folderTrusted(_ dir: URL) -> Bool {
        guard let j = JSONFile.readObject(Paths.claudeGlobalConfig), let projects = j["projects"] as? [String: Any] else { return false }
        for (k, v) in projects where Self.samePath(k, dir.path) {
            return ((v as? [String: Any])?["hasTrustDialogAccepted"] as? Bool) == true
        }
        return false
    }

    func transcript(_ id: String) -> URL {
        Paths.claudeConfigDir.appendingPathComponent("projects/\(Assistant.projectKey(config.clawdHome))/\(id).jsonl")
    }

    /// True when the conversation says Remote Control was lost after the session's process started.
    func rcLost(_ s: Session) -> Bool {
        guard !s.sessionId.isEmpty, let started = s.started, let h = FileHandle(forReadingAtPath: transcript(s.sessionId).path) else { return false }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        let n = min(end, 262_144)
        try? h.seek(toOffset: end - n)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        for line in text.components(separatedBy: "\n") where line.contains("\"content\":\"Remote Control disconnected") {
            if let ts = line.firstMatch(#""timestamp":"([^"]+)""#), let d = ISO8601.parse(ts), d >= started { return true }
        }
        return false
    }

    func argv() -> [String] {
        var cli = ["-n", name]
        let id = sessionId
        if !id.isEmpty && rcRetry < 2 && FileManager.default.fileExists(atPath: transcript(id).path) {
            cli += ["--resume", id]
            if rcRetry == 1 { cli.append("--fork-session") }
        }
        cli += ["--remote-control", name, "--append-system-prompt-file", Paths.resource("prompts/clawd-session-prompt.md").path]
        return cli
    }

    func start() {
        guard let exe = claude() else { return }
        let dir = config.clawdHome
        let args = argv()
        if config.bool("clawdSessionHidden") && folderTrusted(dir) {
            startHidden(exe, args, dir)
        } else {
            startVisible(exe, args, dir)
        }
    }

    /// claude on a pty owned by the app: posix_spawn with the slave side as stdin/out/err.
    func startHidden(_ exe: String, _ args: [String], _ dir: URL) {
        var m: Int32 = -1, s: Int32 = -1
        var ws = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &ws) == 0 else { ErrorLog.write("clawd session", "openpty failed"); return }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, s, 0)
        posix_spawn_file_actions_adddup2(&fa, s, 1)
        posix_spawn_file_actions_adddup2(&fa, s, 2)
        posix_spawn_file_actions_addclose(&fa, m)
        posix_spawn_file_actions_addchdir_np(&fa, dir.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var env = ProcessRunner.environment
        env["TERM"] = "xterm-256color"
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let argvC = ([exe] + args).map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fa, &attr, argvC, envp)
        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        argvC.forEach { free($0) }; envp.forEach { free($0) }
        close(s)
        guard rc == 0 else { close(m); ErrorLog.write("clawd session", "spawn failed: \(rc)"); return }
        stopHidden()
        child = pid; master = m
        ProcessRunner.ownPIDs.remove(pid)
        // Drain the terminal output so the TUI never blocks on a full buffer.
        let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: .global(qos: .background))
        src.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 8192)
            if read(m, &buf, buf.count) <= 0 { src.cancel() }
        }
        src.setCancelHandler { close(m) }
        src.resume()
        drain = src
        DispatchQueue.global().async { var st: Int32 = 0; waitpid(pid, &st, 0) }
    }

    func stopHidden() {
        if child > 0 { kill(-child, SIGTERM); kill(child, SIGTERM) }
        child = 0
        drain?.cancel(); drain = nil
        master = -1
    }

    /// A Terminal window: a .command file opened by Terminal stays open with the exit code.
    func startVisible(_ exe: String, _ args: [String], _ dir: URL) {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/zsh\ncd \(q(dir.path)) || exit 1\n\(q(exe)) \(args.map(q).joined(separator: " "))\necho \"claude exited with code $?\"\n"
        let f = config.dataFile("clawd-session.command")
        try? script.write(to: f, atomically: true, encoding: .utf8)
        chmod(f.path, 0o755)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", f.path]
        try? p.run()
    }

    /// Stops Clawd's session; the next tick starts it again with the current prompt, in the same conversation.
    public func restart(local: [Session]) {
        stopHidden()
        for s in local where s.name == name && Self.samePath(s.cwd, config.clawdHome.path) && s.pid > 0 { kill(s.pid, SIGTERM) }
        launched = .distantPast
        misses = 0
    }

    public func shutdown() { stopHidden() }

    /// Every tick: a session in the home folder - remember Clawd's id; none - start one.
    public func update(local: [Session]) {
        guard config.bool("clawdSession") else {
            if child > 0 { stopHidden() }
            return
        }
        let dir = config.clawdHome.path
        let there = local.filter { Self.samePath($0.cwd, dir) && $0.kind == "interactive" }
        if !there.isEmpty {
            misses = 0
            guard let mine = there.first(where: { $0.name == name }), !mine.sessionId.isEmpty else { return }
            if rcRetry < 3 && rcLost(mine) {
                // Alive but unreachable from the phone - stop it, the next tick starts another.
                rcRetry += 1
                ErrorLog.write("clawd session", "Remote Control lost, \(rcRetry >= 3 ? "giving up until restart" : "restarting")")
                if rcRetry < 3 { kill(mine.pid, SIGTERM); if mine.pid == child { stopHidden() }; launched = .distantPast }
                return
            }
            setSessionId(mine.sessionId)
            return
        }
        // Just started - give it time to show up in the registry.
        if Date().timeIntervalSince(launched) < 180 { return }
        if misses >= 3 { return }
        if launched != .distantPast {
            misses += 1
            if misses >= 3 { ErrorLog.write("clawd session", "did not start three times, giving up until restart"); return }
        }
        launched = Date()
        start()
    }
}
