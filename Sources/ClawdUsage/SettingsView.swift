import AppKit
import ClawdCore
import SwiftUI

struct SettingsActions {
    var lookNow: () -> Void
    var restartSession: () -> Void
    var openSkins: () -> Void
}

/// The settings window: Look, Window, Clawd, Claude Code. Every change is saved and shown at once;
/// the rest (intervals, models, thresholds) is in config.json, linked at the bottom.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var actions: SettingsActions
    @State private var tab = "look"
    var t: Theme { model.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text("\(T("set.title"))  ·  v\(AppModel.version)").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: t.muted))
                Spacer()
            }
            .padding(.top, 30).padding(.horizontal, 18)
            HStack(spacing: 18) {
                ForEach([("look", "set.tabLook"), ("window", "set.tabWindow"), ("clawd", "set.tabClawd"), ("claude", "set.tabClaude")], id: \.0) { id, key in
                    Text(T(key)).font(.system(size: 12, weight: tab == id ? .semibold : .regular))
                        .foregroundColor(Color(hex: tab == id ? t.textHi : t.muted))
                        .contentShape(Rectangle()).onTapGesture { tab = id }
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 10)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case "window": windowPage
                    case "clawd": clawdPage
                    case "claude": ClaudeCodePage(model: model)
                    default: lookPage
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            Text(tab == "claude" ? T("cc.more") : T("set.more")).font(.system(size: 10)).foregroundColor(Color(hex: t.accent))
                .contentShape(Rectangle())
                .onTapGesture {
                    if tab == "claude" { Open.file(model.claudeSettings.url) }
                    else {
                        if !FileManager.default.fileExists(atPath: model.config.url.path) { model.config.save() }
                        NSWorkspace.shared.open(model.config.url)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .background(Color(hex: t.bg))
        .preferredColorScheme(.dark)
    }

    // MARK: building blocks

    func header(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundColor(Color(hex: t.dim)).padding(.top, 8).padding(.bottom, 6)
    }

    func toggle(_ key: String, _ label: String, tip: String = "", onChange: ((Bool) -> Void)? = nil) -> some View {
        let on = model.config.bool(key)
        return SwitchRow(label: label, on: on, tip: tip, theme: t) {
            model.set(key, !on)
            onChange?(!on)
        }
    }

    func chips(_ items: [(String, String)], selected: String, set: @escaping (String) -> Void) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.0) { id, label in
                Text(label).font(.system(size: 11)).foregroundColor(Color(hex: id == selected ? t.textHi : t.text4))
                    .padding(EdgeInsets(top: 3, leading: 10, bottom: 4, trailing: 10))
                    .background(Capsule().fill(Color(hex: id == selected ? t.card2 : t.card)))
                    .contentShape(Capsule()).onTapGesture { set(id) }
            }
        }
        .padding(.bottom, 8)
    }

    func stepper(_ label: String, _ value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5)).foregroundColor(Color(hex: t.text))
            Spacer()
            Text("−").font(.system(size: 14)).foregroundColor(Color(hex: t.muted)).frame(width: 22).contentShape(Rectangle()).onTapGesture(perform: minus)
            Text(value).font(.system(size: 11.5).monospacedDigit()).foregroundColor(Color(hex: t.text2)).frame(width: 48)
            Text("+").font(.system(size: 14)).foregroundColor(Color(hex: t.muted)).frame(width: 22).contentShape(Rectangle()).onTapGesture(perform: plus)
        }
        .padding(.bottom, 8)
    }

    func link(_ s: String, _ action: @escaping () -> Void) -> some View {
        Text(s).font(.system(size: 11)).foregroundColor(Color(hex: t.accent)).contentShape(Rectangle()).onTapGesture(perform: action).padding(.bottom, 8)
    }

    // MARK: pages

    var lookPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(T("set.language"))
            chips(I18n.languages.map { ($0.id, $0.name) }, selected: model.config.string("language")) { model.set("language", $0) }
            header(T("set.theme"))
            chips((["auto"] + Theme.ids).map { ($0, T("theme.\($0)")) }, selected: model.config.string("theme").lowercased()) { model.set("theme", $0) }
            header(T("set.skin"))
            FlowLayout(spacing: 8) {
                ForEach(Skins.all(home: model.config.clawdHome), id: \.id) { s in
                    SkinCard(skin: s, selected: model.config.string("skin").lowercased() == s.id, theme: t) { model.set("skin", s.id) }
                }
                SkinFolderCard(theme: t, action: actions.openSkins).tip(T("set.skinFolderTip"))
            }
            .padding(.bottom, 10)
            stepper(T("set.size"), String(format: "%.0f%%", 100 * model.config.double("scale")),
                    minus: { model.set("scale", max(0.6, ((model.config.double("scale") - 0.1) * 100).rounded() / 100)) },
                    plus: { model.set("scale", min(4.0, ((model.config.double("scale") + 0.1) * 100).rounded() / 100)) })
            stepper(T("set.opacity"), String(format: "%.0f%%", 100 * model.config.double("opacity")),
                    minus: { model.set("opacity", max(0.3, ((model.config.double("opacity") - 0.05) * 100).rounded() / 100)) },
                    plus: { model.set("opacity", min(1.0, ((model.config.double("opacity") + 0.05) * 100).rounded() / 100)) })
        }
    }

    var windowPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always on top and pinned to the desktop exclude each other.
            toggle("topmost", T("set.topmost")) { if $0 { model.set("desktop", false) } }
            toggle("desktop", T("mac.desktop"), tip: T("mac.desktopTip")) { if $0 { model.set("topmost", false) } }
            header(T("set.shown"))
            ForEach(["showMascot", "showSky", "showStatus", "showSessions", "showAccount", "showStats", "showHistory"], id: \.self) { k in
                toggle(k, T("set.\(k)"))
            }
            header(T("set.system"))
            toggle("trayResetClock", T("mac.trayResetClock"))
            LoginRow(theme: t)
        }
    }

    var clawdPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggle("showAdvisor", T("set.showAdvisor"))
            if model.config.bool("showAdvisor") { link(T("mac.advisor")) { actions.lookNow() } }
            toggle("showChat", T("set.showChat"))
            if model.config.bool("showChat") {
                toggle("chatAutoRun", T("set.chatAutoRun"))
                toggle("chatBypass", T("mac.chatBypass"), tip: T("set.chatBypassTip"))
                toggle("chatCompact", T("set.chatCompact"), tip: T("set.chatCompactTip"))
            }
            toggle("showTasks", T("set.showTasks"))
            toggle("clawdSession", T("set.clawdSession"), tip: T("mac.clawdSessionTip"))
            if model.config.bool("clawdSession") {
                toggle("clawdSessionHidden", T("mac.clawdSessionHidden"))
                link(T("set.clawdRestart")) { actions.restartSession() }
            }
            link(T("set.home")) { Open.file(model.config.clawdHome) }
        }
    }
}

/// "Open at login": the state is macOS's own; a failure or a pending approval is said under it.
struct LoginRow: View {
    let theme: Theme
    @State private var on = LaunchAtLogin.isEnabled
    @State private var hint = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchRow(label: T("mac.launchAtLogin"), on: on, tip: T("mac.launchAtLoginTip"), theme: theme) {
                guard LaunchAtLogin.isSupported else { return }
                do {
                    try LaunchAtLogin.setEnabled(!on)
                    hint = ""
                } catch {
                    hint = T("mac.loginFailed", error.localizedDescription)
                }
                refresh()
            }
            .opacity(LaunchAtLogin.isSupported ? 1 : 0.5)
            if !LaunchAtLogin.isSupported || !hint.isEmpty || LaunchAtLogin.needsApproval {
                Text(!LaunchAtLogin.isSupported ? T("mac.loginNoBundle") : !hint.isEmpty ? hint : T("mac.loginApprove"))
                    .font(.system(size: 10)).foregroundColor(Color(hex: theme.dim))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { if LaunchAtLogin.needsApproval { LaunchAtLogin.openLoginItemsSettings() } }
                    .padding(.top, -4).padding(.bottom, 8)
            }
        }
        .onAppear(perform: refresh)
    }

    func refresh() { on = LaunchAtLogin.isSupported && LaunchAtLogin.isEnabled }
}

struct SwitchRow: View {
    let label: String
    let on: Bool
    var tip: String = ""
    let theme: Theme
    let action: () -> Void

    var body: some View {
        HStack {
            Text(label).font(.system(size: 11.5)).foregroundColor(Color(hex: on ? theme.text : theme.text4))
            Spacer(minLength: 10)
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(Color(hex: on ? "#60A5FA" : theme.off)).frame(width: 26, height: 14)
                Circle().fill(Color(hex: "#F4F4F5")).frame(width: 10, height: 10).padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .tip(tip)
        .padding(.bottom, 8)
    }
}

/// A skin with a live preview: he raises his arms under the mouse.
struct SkinCard: View {
    let skin: Skin
    let selected: Bool
    let theme: Theme
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                var f = ClawdFrame()
                if hover { f.arms = "up"; f.eyes = "happy" }
                let g = MascotGeometry.build(f, skin: skin)
                let px = 2.2, py = 2.4
                let ox = (size.width - 18 * px) / 2, oy = size.height - 12 * py + 4
                func fill(_ list: [PxRect], _ c: String) {
                    var p = Path()
                    for q in list { p.addRect(CGRect(x: ox + q.x * px, y: oy + q.y * py, width: q.w * px, height: q.h * py)) }
                    ctx.fill(p, with: .color(Color(hex: c)))
                }
                fill(g.body, skin.body); fill(g.eyes, skin.eyes)
                for a in g.acc { fill(a.rects, a.color) }
            }
            .frame(width: 64, height: 48)
            Text(skin.displayName).font(.system(size: 10)).foregroundColor(Color(hex: selected ? theme.textHi : theme.text4)).lineLimit(1)
        }
        .padding(6)
        .frame(width: 84)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: selected ? theme.card2 : theme.card)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: selected ? theme.accent : "#1AFFFFFF"), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}

struct SkinFolderCard: View {
    let theme: Theme
    let action: () -> Void
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "folder.badge.plus").font(.system(size: 20)).foregroundColor(Color(hex: theme.muted)).frame(width: 64, height: 48)
            Text(T("set.skinFolder")).font(.system(size: 10)).foregroundColor(Color(hex: theme.text4))
        }
        .padding(6).frame(width: 84)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: theme.card)))
        .contentShape(Rectangle()).onTapGesture(perform: action)
    }
}

/// Claude Code's own settings.json: a picked set of keys, each with a hint.
struct ClaudeCodePage: View {
    @ObservedObject var model: AppModel
    @State private var tick = 0
    var t: Theme { model.theme }
    var s: ClaudeSettings { model.claudeSettings }

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 0) {
            Text(T("cc.note", s.url.path)).font(.system(size: 10)).foregroundColor(Color(hex: t.muted))
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            if let err = s.error {
                Text(T("cc.bad", err)).font(.system(size: 11)).foregroundColor(Color(hex: Palette.crit)).padding(.bottom, 8)
            }
            ForEach(ClaudeSettings.items, id: \.key) { it in row(it) }
        }
    }

    func write(_ changes: [(String, OJSON?)]) { s.set(changes); tick += 1 }

    @ViewBuilder func row(_ it: ClaudeSettings.Item) -> some View {
        let tip = TD("cc.\(it.key).tip", default: "")
        switch it.kind {
        case "head":
            Text(T(it.key).uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundColor(Color(hex: t.dim)).padding(.top, 8).padding(.bottom, 6)
        case "toggle":
            let on = s.get(it.key)?.boolValue ?? (it.def == "true")
            SwitchRow(label: T("cc.\(it.key)"), on: on, tip: tip, theme: t) { write([(it.key, .bool(!on))]) }
        case "attribution":
            let commit = s.get("attribution.commit")
            let on = commit == nil || commit?.stringValue != ""
            SwitchRow(label: T("cc.attribution"), on: on, tip: tip, theme: t) {
                if on { write([("attribution.commit", .string("")), ("attribution.pr", .string(""))]) }
                else { write([("attribution.commit", nil), ("attribution.pr", nil)]) }
            }
        case "days":
            let n = s.get(it.key)?.intValue ?? Int(it.def ?? "30") ?? 30
            HStack {
                Text(T("cc.\(it.key)")).font(.system(size: 11.5)).foregroundColor(Color(hex: t.text))
                Spacer()
                Text("−").font(.system(size: 14)).foregroundColor(Color(hex: t.muted)).frame(width: 22).contentShape(Rectangle())
                    .onTapGesture { if let lower = it.steps.last(where: { $0 < n }) { write([(it.key, .number(String(lower)))]) } }
                Text(T("cc.days", n)).font(.system(size: 11.5)).foregroundColor(Color(hex: t.text2)).frame(width: 70)
                Text("+").font(.system(size: 14)).foregroundColor(Color(hex: t.muted)).frame(width: 22).contentShape(Rectangle())
                    .onTapGesture { if let higher = it.steps.first(where: { $0 > n }) { write([(it.key, .number(String(higher)))]) } }
            }
            .contentShape(Rectangle()).tip(tip).padding(.bottom, 8)
        default:
            let cur = s.get(it.key)?.stringValue ?? (it.def ?? "")
            var opts = it.opts
            let _ = !opts.contains(cur) ? opts.append(cur) : ()
            VStack(alignment: .leading, spacing: 4) {
                Text(T("cc.\(it.key)")).font(.system(size: 11.5)).foregroundColor(Color(hex: t.text)).tip(tip)
                FlowLayout(spacing: 6) {
                    ForEach(opts, id: \.self) { v in
                        Text(v.isEmpty ? T("cc.unset") : TD("cc.\(it.key).\(v)", default: v)).font(.system(size: 10.5))
                            .foregroundColor(Color(hex: v == cur ? t.textHi : t.text4))
                            .padding(EdgeInsets(top: 3, leading: 9, bottom: 4, trailing: 9))
                            .background(Capsule().fill(Color(hex: v == cur ? t.card2 : t.card)))
                            .contentShape(Capsule())
                            .onTapGesture { write([(it.key, v.isEmpty ? nil : .string(v))]) }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }
}
