import AppKit
import ClawdCore
import SwiftUI
import UserNotifications

extension Color {
    /// "#RRGGBB" or "#AARRGGBB".
    init(hex: String) { self.init(rgba: RGBA(hex)) }
    init(rgba c: RGBA) {
        self.init(.sRGB, red: c.r / 255, green: c.g / 255, blue: c.b / 255, opacity: c.a / 255)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let c = RGBA(hex)
        self.init(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: c.a / 255)
    }
}

/// System notifications. UNUserNotificationCenter needs a real app bundle; a bare `swift run`
/// binary falls back to `osascript display notification`.
enum Notifier {
    static var onClick: (() -> Void)?
    static let delegate = Delegate()

    static var bundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func setUp() {
        guard bundled else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, id: String = UUID().uuidString) {
        if bundled {
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } else {
            func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(q(body))\" with title \"\(q(title))\""]
            try? p.run()
        }
    }

    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            DispatchQueue.main.async { Notifier.onClick?() }
            completionHandler()
        }
    }
}

/// Hover tooltips that work while the app is in the background (an accessory app is rarely
/// active, and AppKit only shows its own tooltips for the active app).
final class HoverTip {
    static let shared = HoverTip()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var pending: DispatchWorkItem?
    private var owner: UUID?

    func show(_ text: String, owner id: UUID, delay: Double = 0.45) {
        pending?.cancel()
        guard !text.isEmpty else { hide(owner: id); return }
        if owner == id, panel?.isVisible == true { update(text); return }
        let work = DispatchWorkItem { [weak self] in self?.present(text, id) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func update(_ text: String) {
        guard let label, let panel, label.stringValue != text else { return }
        label.stringValue = text
        layout(panel, label, at: NSEvent.mouseLocation)
    }

    func hide(owner id: UUID) {
        guard owner == id || owner == nil else { return }
        pending?.cancel(); pending = nil
        panel?.orderOut(nil)
        owner = nil
    }

    private func present(_ text: String, _ id: UUID) {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let box = NSVisualEffectView()
            box.material = .toolTip
            box.state = .active
            box.wantsLayer = true
            box.layer?.cornerRadius = 6
            let l = NSTextField(wrappingLabelWithString: "")
            l.font = .systemFont(ofSize: 11)
            l.textColor = .labelColor
            l.preferredMaxLayoutWidth = 420
            box.addSubview(l)
            p.contentView = box
            panel = p; label = l
        }
        owner = id
        label!.stringValue = text
        layout(panel!, label!, at: NSEvent.mouseLocation)
        panel!.orderFrontRegardless()
    }

    private func layout(_ p: NSPanel, _ l: NSTextField, at mouse: NSPoint) {
        let size = l.sizeThatFits(NSSize(width: 420, height: 2000))
        l.frame = NSRect(x: 8, y: 6, width: min(420, size.width), height: size.height)
        var frame = NSRect(x: mouse.x + 12, y: mouse.y - size.height - 26, width: min(420, size.width) + 16, height: size.height + 12)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            if frame.maxX > v.maxX { frame.origin.x = v.maxX - frame.width - 4 }
            if frame.minY < v.minY { frame.origin.y = mouse.y + 16 }
        }
        p.setFrame(frame, display: true)
    }
}

struct HoverTipModifier: ViewModifier {
    let text: () -> String
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { HoverTip.shared.show(text(), owner: id) } else { HoverTip.shared.hide(owner: id) }
        }
        .onDisappear { HoverTip.shared.hide(owner: id) }
    }
}

extension View {
    /// A tooltip that also shows while the app is inactive. The text is read when the hover starts.
    func tip(_ text: @autoclosure @escaping () -> String) -> some View { modifier(HoverTipModifier(text: text)) }

    @ViewBuilder func `if`<C: View>(_ cond: Bool, _ f: (Self) -> C) -> some View { if cond { f(self) } else { self } }
}

/// Scales its content: proposes the unscaled size, reports the scaled one.
struct Scaled: Layout {
    var k: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let inner = s.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 / k }, height: proposal.height.map { $0 / k }))
        return CGSize(width: inner.width * k, height: inner.height * k)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let s = subviews.first else { return }
        let inner = s.sizeThatFits(ProposedViewSize(width: bounds.width / k, height: bounds.height / k))
        s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(inner))
    }
}

enum Open {
    static func url(_ s: String) {
        if s.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: s)) }
        else if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
    static func file(_ u: URL) { NSWorkspace.shared.open(u) }
    static func reveal(_ u: URL) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
}
