import AppKit
import ClawdCore
import SwiftUI

/// Mouse position over a window, tracked even while the app is inactive.
final class MouseTracker: ObservableObject {
    @Published var inside = false
    /// In window coordinates, flipped (top-left origin).
    @Published var location: CGPoint = .zero
}

/// Hosting view that resizes its window to the SwiftUI content, keeping the top-left corner
/// fixed (the window grows down when details open), and tracks the mouse with `activeAlways`.
final class AutoSizingHostingView<Content: View>: NSHostingView<Content> {
    var tracker: MouseTracker?
    private var resizeScheduled = false
    private var area: NSTrackingArea?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        scheduleResize()
    }

    override func layout() {
        super.layout()
        scheduleResize()
    }

    func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            self.resizeScheduled = false
            let size = self.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            let f = w.frame
            if abs(f.width - size.width) < 0.5 && abs(f.height - size.height) < 0.5 { return }
            w.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    private func report(_ e: NSEvent, inside: Bool) {
        guard let tracker else { return }
        let p = convert(e.locationInWindow, from: nil)
        tracker.location = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        if tracker.inside != inside { tracker.inside = inside }
    }
    override func mouseEntered(with e: NSEvent) { super.mouseEntered(with: e); report(e, inside: true) }
    override func mouseMoved(with e: NSEvent) { super.mouseMoved(with: e); report(e, inside: true) }
    override func mouseExited(with e: NSEvent) { super.mouseExited(with: e); report(e, inside: false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless floating panel. `keyable`: may take the keyboard (the chat's text field) without
/// activating the app.
final class FloatingPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    init(keyable: Bool = false) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.keyable = keyable
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }

    func host<V: View>(_ view: V, tracker: MouseTracker? = nil) {
        let h = AutoSizingHostingView(rootView: view)
        h.tracker = tracker
        contentView = h
        h.scheduleResize()
    }
}

/// A normal titled window for Settings (it needs focus, text fields and pickers).
final class SettingsWindow: NSWindow {
    init<V: View>(_ view: V) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Clawd Usage"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: view)
        minSize = NSSize(width: 560, height: 440)
        center()
    }
}
