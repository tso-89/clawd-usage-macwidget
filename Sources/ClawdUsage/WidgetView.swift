import AppKit
import ClawdCore
import SwiftUI

/// The floating window: header, the session percentage with Clawd, week and Fable bars, sessions,
/// service status, details, account line. Layout follows upstream widget.xaml (262 pt wide).
struct WidgetView: View {
    @ObservedObject var model: AppModel
    let anim: Animator          // observed only by the views that animate
    let tracker: MouseTracker
    @ObservedObject var badge: PanelBadge
    var actions: WidgetActions

    static let width: CGFloat = 262
    static let barWidth: CGFloat = 238

    var t: Theme { model.theme }

    var body: some View {
        let k = CGFloat(min(4, max(0.6, model.config.double("scale"))))
        Scaled(k: k) {
            content
                .frame(width: Self.width)
                .scaleEffect(k, anchor: .topLeading)
        }
        .opacity(model.config.double("opacity") <= 0 ? 1 : min(1, model.config.double("opacity")))
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 6)
            TopRow(model: model, anim: anim, tracker: tracker, pctColor: Color(hex: Palette.level(model.level)))
                .coordinateSpace(name: "mascot")
                .padding(.bottom, 4)
            bar(model.usage?.session, height: 6, radius: 3, color: Color(hex: Palette.level(model.level)))
                .padding(.bottom, 7)
                .accessibilityElement()
                .accessibilityLabel("\(T("tray.session", model.usage?.session ?? 0)), \(model.resetLine)")
            Text(model.resetLine).font(.system(size: 11)).foregroundColor(Color(hex: t.text2)).padding(.bottom, 9)
            limitRow(T("ui.week"), model.limitLine(model.usage?.week, model.usage?.weekReset))
            bar(model.usage?.week, height: 4, radius: 2, color: Color(hex: t.accent)).padding(.bottom, 7)
                .accessibilityElement().accessibilityLabel("\(T("ui.week")) \(model.limitLine(model.usage?.week, model.usage?.weekReset))")
            if let f = model.usage?.fable {
                limitRow(T("ui.fable"), model.limitLine(f, model.usage?.fableReset))
                bar(f, height: 4, radius: 2, color: Color(hex: "#A78BFA"))
            }
            if model.config.bool("showSessions") { sessions.padding(.top, 10) }
            if model.config.bool("showStatus") { status.padding(.top, 10) }
            if model.expanded { DetailsView(model: model, actions: actions).padding(.top, 11) }
            footer.padding(.top, 7)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 11, trailing: 12))
        .background(background)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onContinuousHover(coordinateSpace: .named("mascot")) { phase in
            switch phase {
            case .active(let p): anim.mouseOver = true; anim.mouseX = p.x - 10 - pctWidth
            case .ended: anim.mouseOver = false; anim.mouseX = nil
            }
        }
    }

    /// Width of the percentage text: the mascot area starts after it (and a 10 pt gap).
    var pctWidth: CGFloat {
        let s = model.usage?.session.map(String.init) ?? "--"
        return (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .light)]).width + 2
            + ("%" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
    }

    var background: some View {
        ZStack {
            Color(hex: t.bg)
            if let name = t.pattern, let p = ThemePattern.named(name) {
                Canvas { ctx, size in
                    var y = 0.0
                    while y < size.height {
                        var x = 0.0
                        while x < size.width {
                            for r in p.rects {
                                ctx.fill(Path(CGRect(x: x + r.rect.x, y: y + r.rect.y, width: r.rect.w, height: r.rect.h)),
                                         with: .color(Color(hex: r.color).opacity(p.opacity)))
                            }
                            x += p.tile
                        }
                        y += p.tile
                    }
                }
            }
        }
    }

    var header: some View {
        HStack(spacing: 0) {
            Text("CLAUDE USAGE").font(.system(size: 9.5, weight: .semibold)).foregroundColor(Color(hex: t.muted))
            Spacer(minLength: 4)
            if badge.visible {
                HStack(spacing: 2) {
                    Image(systemName: badge.icon).font(.system(size: 10))
                    if !badge.count.isEmpty { Text(badge.count).font(.system(size: 9.5, weight: .semibold)) }
                }
                .foregroundColor(Color(hex: badge.color))
                .contentShape(Rectangle())
                .onTapGesture { actions.togglePanel() }
                .tip(badge.tip)
                .padding(.trailing, 12)
            }
            HeartsView(anim: anim, theme: t).padding(.trailing, 12)
            iconButton("gearshape", T("set.tip")) { actions.toggleSettings() }.padding(.trailing, 10)
            Text(model.expanded ? "▴" : "▾").font(.system(size: 11)).foregroundColor(Color(hex: t.muted))
                .contentShape(Rectangle()).onTapGesture { model.toggleDetails() }.tip(T("ui.details")).padding(.trailing, 9)
            Text("–").font(.system(size: 13)).foregroundColor(Color(hex: t.muted))
                .contentShape(Rectangle()).onTapGesture { actions.hideWidget() }.tip(T("mac.hide")).padding(.trailing, 9)
            Text("✕").font(.system(size: 11)).foregroundColor(Color(hex: t.muted))
                .contentShape(Rectangle()).onTapGesture { NSApp.terminate(nil) }.tip(T("ui.exit"))
        }
    }

    func iconButton(_ name: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: name).font(.system(size: 10)).foregroundColor(Color(hex: t.muted))
            .contentShape(Rectangle()).onTapGesture(perform: action).tip(tip)
    }

    func bar(_ pct: Int?, height: CGFloat, radius: CGFloat, color: Color) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.15))
            RoundedRectangle(cornerRadius: radius).fill(color)
                .frame(width: max(0, CGFloat(min(100, pct ?? 0)) / 100 * Self.barWidth))
        }
        .frame(height: height)
    }

    func limitRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(hex: t.dim))
            Spacer()
            Text(value).font(.system(size: 10)).foregroundColor(Color(hex: t.muted))
        }
        .padding(.bottom, 4)
    }

    var sessions: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(T("ui.sessions")).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(hex: t.dim)).padding(.trailing, 8)
            Spacer(minLength: 0)
            Text(model.sessionsLine).font(.system(size: 10)).foregroundColor(Color(hex: t.muted)).lineLimit(1).truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .tip(model.sessions.map(\.hoverLine).joined(separator: "\n"))
    }

    var status: some View {
        let s = model.statusDisplay
        return HStack(alignment: .top, spacing: 6) {
            Circle().fill(Color(hex: s.dot)).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(s.text).font(.system(size: 10.5)).foregroundColor(Color(hex: s.fg)).fixedSize(horizontal: false, vertical: true)
                if !s.extra.isEmpty {
                    Text(s.extra).font(.system(size: 10)).foregroundColor(Color(hex: t.muted)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { Open.url(StatusProbe.page) }
        .tip(T("ui.openStatus"))
    }

    var footer: some View {
        let a = model.accountLine
        return HStack {
            Text(a.text).font(.system(size: 9)).foregroundColor(Color(hex: a.color)).lineLimit(1).truncationMode(.tail)
                .tip(a.text)
            Spacer(minLength: 8)
            Text(model.stampLine).font(.system(size: 9)).foregroundColor(Color(hex: model.lastError ? Palette.crit : t.faint))
        }
    }
}

/// What the views can ask of the app delegate.
struct WidgetActions {
    var togglePanel: () -> Void
    var toggleSettings: () -> Void
    var hideWidget: () -> Void
}

/// The header icon of Clawd's panel: what is waiting there.
final class PanelBadge: ObservableObject {
    @Published var visible = false
    @Published var icon = "bubble.left"
    @Published var color = "#8B8B94"
    @Published var count = ""
    @Published var tip = ""
}
