import AppKit
import ClawdCore
import SwiftUI

/// Expanded details: the 24h / 7d stats, the 7-day limits chart, top projects, versions.
struct DetailsView: View {
    @ObservedObject var model: AppModel
    var actions: WidgetActions
    var t: Theme { model.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.config.bool("showStats") {
                divider
                period(T("ui.day"), model.usage?.day)
                period(T("ui.week7"), model.usage?.week7)
            }
            if model.config.bool("showHistory") {
                divider
                HistoryChart(model: model)
                projects
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.bottom, 7)
            versions
        }
    }

    var divider: some View { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.bottom, 8) }

    func label(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(hex: t.dim))
    }

    func period(_ title: String, _ p: UsagePeriod?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label(title).padding(.bottom, 3)
            if let p {
                Text("\(formatCount(p.requests, "request"))  ·  \(formatCount(p.sessions, "session"))")
                    .font(.system(size: 10.5)).foregroundColor(Color(hex: t.text2)).padding(.bottom, 2)
                Text(p.lines.map(UsageParser.formatStatLine).joined(separator: "  ·  "))
                    .font(.system(size: 10)).foregroundColor(Color(hex: t.muted)).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            } else {
                Text(T("noData")).font(.system(size: 10.5)).foregroundColor(Color(hex: t.text2)).padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder var projects: some View {
        let p = model.history.projects
        let top = p?.top ?? []
        if p == nil || !top.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                label(T("ui.projects")).padding(.bottom, 2).tip(T("hist.projTip"))
                if p == nil {
                    Text(T("hist.counting")).font(.system(size: 10)).foregroundColor(Color(hex: t.dim))
                }
                ForEach(top, id: \.name) { e in
                    HStack(spacing: 0) {
                        Text(e.name).font(.system(size: 10)).foregroundColor(Color(hex: t.text2)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.15))
                            RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#D77757")).frame(width: max(2, 70 * e.share / 100))
                        }
                        .frame(width: 70, height: 4)
                        Text(String(format: "%.0f%%", e.share)).font(.system(size: 10)).foregroundColor(Color(hex: t.muted))
                            .frame(width: 34, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .tip(e.path)
                }
            }
            .padding(.bottom, 10)
        }
    }

    var versions: some View {
        let v = model.versionLine
        let w = model.widgetVersionLine
        return HStack(alignment: .top) {
            Text(v.text).font(.system(size: 10)).foregroundColor(Color(hex: v.color)).fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.versionProbe.updateAvailable { model.runClaudeUpdate() } else { Open.url(VersionProbe.changelogPage) }
                }
                .tip(model.versionProbe.tooltip())
            Spacer(minLength: 8)
            Text(w.text).font(.system(size: 10)).foregroundColor(Color(hex: w.color))
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.releaseProbe.newer(than: AppModel.version), let r = model.releaseProbe.latest, !r.url.isEmpty { Open.url(r.url) }
                    else if !ReleaseProbe.repo.isEmpty { Open.url("https://github.com/\(ReleaseProbe.repo)/blob/main/CHANGELOG.md") }
                    else { Open.file(Paths.resource("CHANGELOG.md")) }
                }
                .tip(w.tip)
        }
    }
}

/// LIMITS · 7 DAYS: the 5-hour (green) and weekly (blue) percentages; hover tells the moment.
struct HistoryChart: View {
    @ObservedObject var model: AppModel
    @State private var hoverX: CGFloat?
    static let H: CGFloat = 44
    var t: Theme { model.theme }

    var body: some View {
        let W = WidgetView.barWidth
        let t1 = UsageHistory.minute(Date()), t0 = t1 - 7 * 1440
        VStack(alignment: .leading, spacing: 0) {
            Text(T("ui.hist")).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(hex: t.dim)).padding(.bottom, 4)
            Canvas { ctx, size in
                // Midnights.
                let cal = Calendar.current
                var day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date(timeIntervalSince1970: Double(t0) * 60)))!
                while day < Date() {
                    let x = W * CGFloat(UsageHistory.minute(day) - t0) / CGFloat(t1 - t0)
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: Self.H)), with: .color(Color.white.opacity(0.1)))
                    day = cal.date(byAdding: .day, value: 1, to: day)!
                }
                for (series, color) in [(2, Color(hex: "#60A5FA")), (1, Color(hex: "#4ADE80"))] {
                    for run in model.history.runs(series: series, from: t0, to: t1) {
                        var pts = run.map { CGPoint(x: W * $0.0, y: 1 + (Self.H - 2) * (1 - $0.1)) }
                        if pts.count == 1 { pts.append(CGPoint(x: pts[0].x + 1, y: pts[0].y)) }
                        var line = Path()
                        line.addLines(pts)
                        if series == 1 {
                            var area = Path()
                            area.move(to: CGPoint(x: pts[0].x, y: Self.H))
                            area.addLines(pts)
                            area.addLine(to: CGPoint(x: pts.last!.x, y: Self.H))
                            area.closeSubpath()
                            ctx.fill(area, with: .color(Color(hex: "#264ADE80")))
                        }
                        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    }
                }
                if let x = hoverX {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: Self.H)), with: .color(Color.white.opacity(0.4)))
                }
            }
            .frame(width: W, height: Self.H)
            .clipped()
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = max(0, min(W, p.x)) } else { hoverX = nil }
            }
            dayNames(t0: t0, t1: t1, W: W)
            caption(t0: t0, t1: t1, W: W)
                .font(.system(size: 10)).foregroundColor(Color(hex: t.muted)).lineLimit(1).truncationMode(.tail)
                .padding(.top, 1).padding(.bottom, 10)
        }
    }

    func dayNames(t0: Int, t1: Int, W: CGFloat) -> some View {
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = I18n.locale; f.dateFormat = "EEE"
        var items: [(String, CGFloat, CGFloat)] = []
        var day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date(timeIntervalSince1970: Double(t0) * 60)))!
        var prev: CGFloat = 0
        while true {
            let x = day < Date() ? W * CGFloat(UsageHistory.minute(day) - t0) / CGFloat(t1 - t0) : W
            let name = f.string(from: cal.date(byAdding: .day, value: -1, to: day)!)
            if x - prev >= 14 { items.append((name, prev, x - prev)) }
            if day >= Date() { break }
            prev = x
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.1) { it in
                Text(it.0).font(.system(size: 8)).foregroundColor(Color(hex: t.faint))
                    .frame(width: it.2).offset(x: it.1)
            }
        }
        .frame(width: W, height: 11, alignment: .topLeading)
    }

    func hoverCaption(_ x: CGFloat, t0: Int, t1: Int, W: CGFloat) -> String {
        let tm = t0 + Int(CGFloat(t1 - t0) * x / W)
        let f = DateFormatter(); f.locale = I18n.locale; f.dateFormat = "EEE HH:mm"
        var parts = [f.string(from: Date(timeIntervalSince1970: Double(tm) * 60))]
        if let s = model.history.sample(at: tm) {
            if s.session >= 0 { parts.append("\(T("hist.session")) \(s.session)%") }
            if s.week >= 0 { parts.append("\(T("hist.week")) \(s.week)%") }
        } else { parts.append(T("noData")) }
        if let top = model.history.projects?.hours[tm / 60]?.max(by: { $0.value < $1.value })?.key { parts.append(top) }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder func caption(t0: Int, t1: Int, W: CGFloat) -> some View {
        if let x = hoverX {
            Text(hoverCaption(x, t0: t0, t1: t1, W: W))
        } else if model.history.samples.isEmpty {
            Text(T("hist.empty"))
        } else {
            (Text("━ ").foregroundColor(Color(hex: "#4ADE80")) + Text(T("hist.session") + "    ")
                + Text("━ ").foregroundColor(Color(hex: "#60A5FA")) + Text(T("hist.week")))
        }
    }
}
