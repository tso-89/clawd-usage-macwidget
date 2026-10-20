import Foundation

/// Result of a finished child process.
public struct ProcessResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

/// Runs a child with an argument array (never through a shell, so `/usage` stays `/usage`),
/// captures output, enforces a timeout and remembers its PID while running - the sessions
/// list skips our own `claude` children.
public final class ProcessRunner: @unchecked Sendable {
    public static let ownPIDs = PIDSet()

    /// Environment for children: the login shell's PATH (a GUI app gets a minimal one), so
    /// `claude` finds node, git and the rest.
    public static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        if let path = LoginShell.path { env["PATH"] = path }
        return env
    }()

    public final class Handle: @unchecked Sendable {
        public let process: Process
        public var pid: Int32 { process.processIdentifier }
        init(_ p: Process) { process = p }
        public func cancel() {
            if process.isRunning { process.terminate() }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if pid > 0 { kill(pid, SIGKILL) } }
        }
        public var isRunning: Bool { process.isRunning }
    }

    /// Starts a process; `onLine` gets stdout lines as they arrive (stream-json), `completion` the result.
    @discardableResult
    public static func run(_ exe: String, _ args: [String], cwd: URL? = nil, stdin: String? = nil,
                           timeout: TimeInterval? = nil, env extra: [String: String] = [:],
                           onLine: ((String) -> Void)? = nil,
                           completion: @escaping (ProcessResult) -> Void) -> Handle? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = environment
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        let lock = NSLock()
        var outData = Data(), errData = Data(), lineBuf = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); outData.append(d)
            var lines: [String] = []
            if onLine != nil {
                lineBuf.append(d)
                while let nl = lineBuf.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: lineBuf[lineBuf.startIndex..<nl], as: UTF8.self))
                    lineBuf.removeSubrange(lineBuf.startIndex...nl)
                }
            }
            lock.unlock()
            for l in lines { onLine?(l) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); errData.append(d); lock.unlock()
        }
        let handle = Handle(p)
        var timedOut = false
        p.terminationHandler = { proc in
            ownPIDs.remove(proc.processIdentifier)
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let restOut = (try? out.fileHandleForReading.readToEnd()) ?? nil
            let restErr = (try? err.fileHandleForReading.readToEnd()) ?? nil
            lock.lock()
            if let restOut { outData.append(restOut); if onLine != nil { lineBuf.append(restOut) } }
            if let restErr { errData.append(restErr) }
            let tail = String(decoding: lineBuf, as: UTF8.self)
            let r = ProcessResult(status: proc.terminationStatus,
                                  stdout: String(decoding: outData, as: UTF8.self),
                                  stderr: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
            lock.unlock()
            if !tail.isEmpty { for l in tail.split(separator: "\n") { onLine?(String(l)) } }
            DispatchQueue.main.async { completion(r) }
        }
        do { try p.run() } catch {
            ErrorLog.write("spawn", "\(exe): \(error.localizedDescription)")
            return nil
        }
        ownPIDs.insert(p.processIdentifier)
        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { timedOut = true; handle.cancel() }
            }
        }
        return handle
    }

    /// Blocking variant for background work (advisor scans, tests).
    public static func runSync(_ exe: String, _ args: [String], timeout: TimeInterval = 20) -> ProcessResult? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "", timedOut: false)
    }
}

public final class PIDSet: @unchecked Sendable {
    private var set = Set<Int32>()
    private let lock = NSLock()
    public func insert(_ p: Int32) { lock.lock(); set.insert(p); lock.unlock() }
    public func remove(_ p: Int32) { lock.lock(); set.remove(p); lock.unlock() }
    public func contains(_ p: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(p) }
}

/// The user's login shell PATH. A Finder-launched app gets /usr/bin:/bin:/usr/sbin:/sbin only.
public enum LoginShell {
    public static let path: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let r = ProcessRunner.runSyncRaw(shell, ["-lic", "printf '__P__%s' \"$PATH\""], timeout: 5) else { return nil }
        guard let range = r.range(of: "__P__") else { return nil }
        let p = String(r[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : p
    }()
}

extension ProcessRunner {
    /// Like runSync but with the inherited environment (used before `environment` exists).
    static func runSyncRaw(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let g = DispatchGroup(); g.enter()
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        if g.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Finds the `claude` binary: config `claudePath`, the usual install locations, then the login shell.
public enum ClaudeLocator {
    public static func find(configured: String) -> String? {
        let fm = FileManager.default
        if !configured.isEmpty {
            let p = (configured as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: p) { return p }
        }
        let home = Paths.home.path
        for p in ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                  "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"] where fm.isExecutableFile(atPath: p) {
            return p
        }
        for dir in (LoginShell.path ?? "").split(separator: ":") {
            let p = "\(dir)/claude"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
