import AppKit
import ClawdCore
import SwiftUI

/// A reminder that went off shows as a card in the top-right corner, where macOS shows its own
/// notifications: put it off (+15m, +1h, +3h, tomorrow 9:00, or any time in the Reminders tab)
/// or mark it done. It stays until answered; several stack up.
final class RemindPopups {
    let model: AppModel
    var popups: [(panel: FloatingPanel, r: Reminder, done: URL?)] = []
    var openPanelAt: ((String) -> Void)?
    var canShow: Bool { true }

    init(model: AppModel) { self.model = model }

    func show(_ r: Reminder, donePath: URL?, text: String) {
        let p = FloatingPanel(keyable: false)
        p.level = .statusBar
        let id = UUID()
        p.host(RemindCard(model: model, reminder: r, text: text,
                          later: { [weak self] when in self?.later(id, when) },
                          other: { [weak self] in self?.other(id) },
                          done: { [weak self] in self?.close(id) }))
        p.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        popups.append((p, r, donePath))
        p.orderFrontRegardless()
        DispatchQueue.main.async { self.place() }
        NSSound(named: "Glass")?.play()
    }

    /// Stacked from the top of the visible area down, newest at the top.
    func place() {
        guard let v = NSScreen.main?.visibleFrame else { return }
        var y = v.maxY - 4
        for p in popups.reversed() {
            let f = p.panel.frame
            p.panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - f.width - 4, y: y))
            y -= f.height + 4
        }
    }

    func find(_ id: UUID) -> Int? { popups.firstIndex { $0.panel.identifier?.rawValue == id.uuidString } }

    func close(_ id: UUID) {
        guard let i = find(id) else { return }
        popups[i].panel.orderOut(nil)
        popups.remove(at: i)
        place()
    }

    /// Put off: the reminder file again, for the new time; the fired copy goes.
    func later(_ id: UUID, _ when: String) {
        guard let i = find(id), let at = WhenParser.parse(when) else { return }
        let p = popups[i]
        model.assistant.reminders.create(at: at, text: p.r.text)
        if let d = p.done { try? FileManager.default.removeItem(at: d) }
        model.assistant.add("note", T("pop.later", ReminderStore.formatTime(at), p.r.text))
        close(id)
    }

    /// Any other time: the Reminders tab with the text in the form.
    func other(_ id: UUID) {
        guard let i = find(id) else { return }
        let p = popups[i]
        if let d = p.done { try? FileManager.default.removeItem(at: d) }
        close(id)
        if let app = NSApp.delegate as? AppDelegate {
            app.showPanel()
            app.panelState.tab = "remind"
            app.panelState.remText = p.r.text
        }
    }
}

struct RemindCard: View {
    @ObservedObject var model: AppModel
    let reminder: Reminder
    let text: String
    let later: (String) -> Void
    let other: () -> Void
    let done: () -> Void
    var t: Theme { model.theme }

    var body: some View {
        let k = CGFloat(min(4, max(0.6, model.config.double("scale"))))
        Scaled(k: k) {
            card.frame(width: 270).scaleEffect(k, anchor: .topLeading)
        }
    }

    var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bell.fill").font(.system(size: 10)).foregroundColor(Color(hex: "#D77757"))
                Text(T("chat.remindTitle")).font(.system(size: 9.5, weight: .semibold)).foregroundColor(Color(hex: t.muted))
                Spacer()
                Text(ReminderStore.formatTime(reminder.at)).font(.system(size: 9.5)).foregroundColor(Color(hex: t.dim))
            }
            .padding(.bottom, 5)
            Text(text).font(.system(size: 12.5)).foregroundColor(Color(hex: t.textHi)).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            Text(T("pop.laterHead")).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(hex: t.dim)).padding(.bottom, 3)
            FlowLayout(spacing: 5) {
                ForEach(TA("pop.snooze"), id: \.self) { c in chip(c) { later(c) } }
                chip("…", other)
            }
            HStack {
                Spacer()
                Text(T("pop.done")).font(.system(size: 10.5)).foregroundColor(Color(hex: Palette.ok)).contentShape(Rectangle()).onTapGesture(perform: done)
            }
            .padding(.top, 6)
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 10, trailing: 12))
        .background(Color(hex: t.bg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: "#D77757"), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func chip(_ s: String, _ action: @escaping () -> Void) -> some View {
        Text(s).font(.system(size: 10)).foregroundColor(Color(hex: t.muted))
            .padding(EdgeInsets(top: 2, leading: 8, bottom: 3, trailing: 8))
            .background(Capsule().fill(Color(hex: t.card)))
            .contentShape(Capsule()).onTapGesture(perform: action)
    }
}
