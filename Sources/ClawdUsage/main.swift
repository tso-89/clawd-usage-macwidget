import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { RenderTool.run(CommandLine.arguments[i + 1]) }
    exit(0)
}

// One instance per user: autostart plus a manual start would give two menu bar items.
let lockName = "clawd-usage-macwidget" + (ProcessInfo.processInfo.environment["CLAWD_SMOKE"] != nil ? "-smoke" : "")
let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(lockName).lock")
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
