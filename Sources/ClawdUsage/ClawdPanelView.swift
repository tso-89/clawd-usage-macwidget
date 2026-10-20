import AppKit
import ClawdCore
import SwiftUI

/// The panel's view state, refreshed by the app on changes and ticks.
final class PanelState: ObservableObject {
    let model: AppModel
    @Published var tab = "chat"
    @Published var input = ""
    @Published var hint = ""
    @Published var tipRef: String?
    @Published var remindDue = 0
    // Reminders form.
    @Published var remText = ""
    @Published var remWhen = ""
    @Published var remEdit: Reminder?
    @Published var whenAsking: String?
    @Published var whenBad: String?
    @Published var taskOpen: String?
    // Lists.
    @Published var listCur: String?
    @Published var listNew = false
    @Published var listAdd = ""
    @Published var tick = 0
    @Published var scrollToken = 0
    private var lastFeedCount = -1

    init(model: AppModel) { self.model = model }

    var a: Assistant { model.assistant }

    func refresh() {
        tick += 1
        let n = a.feed.count
        if n != lastFeedCount { lastFeedCount = n; scrollToken += 1 }
    }

    func submitChat() {
        guard !a.chatBusy else { return }
        var t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input = ""
        if let ref = tipRef { t = T("adv.refineMsg", ref, t); tipRef = nil }
        if let pending = a.messages.last(where: { $0.run?.state == "pending" }), hint == T("chat.refineHint") {
            hint = ""
            a.refineRun(pending, t)
            return
        }
        hint = ""
        a.send(t)
    }

    // Reminders.
    static func isRepeat(_ when: String) -> Bool {
        when.trimmingCharacters(in: .whitespaces).lowercased()
            .range(of: #"^(раз в|раз во|каждый|каждую|каждое|каждые|ежедневно|ежечасно|every|each|hourly|daily|chaque|tous les|toutes les)(\s|$)"#,
                   options: .regularExpression) != nil
    }

    var parsedWhen: (String, String)? {
        let w = remWhen.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return nil }
        if let at = WhenParser.parse(w) { return ("→ " + ReminderStore.formatTime(at), model.theme.muted) }
        if Self.isRepeat(w) { return (T("rem.repeat"), "#60A5FA") }
        if whenAsking == w { return (T("rem.whenAsking"), model.theme.muted) }
        if whenBad == w { return (T("rem.badWhen"), Palette.crit) }
        return (T("rem.whenAsk"), model.theme.dim)
    }

    func saveReminder() {
        let text = remText.trimmingCharacters(in: .whitespacesAndNewlines)
        let when = remWhen.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !when.isEmpty else { return }
        if let at = WhenParser.parse(when) { save(at, text, remEdit); resetRem(); return }
        // "Every half an hour" is a recurring task: Clawd makes it in the chat (he knows the tools it needs).
        if Self.isRepeat(when), model.config.bool("showChat"), !a.chatBusy {
            a.send(T("rem.repeatMsg", text, when)); resetRem(); tab = "chat"; return
        }
        guard when != whenBad, whenAsking == nil, let claude = model.claudePath else { return }
        whenAsking = when
        let edit = remEdit
        WhenParser.ask(when, claude: claude, model: model.config.string("quickModel")) { [weak self] at in
            guard let self else { return }
            self.whenAsking = nil
            if let at {
                self.save(at, text, edit)
                if self.remWhen.trimmingCharacters(in: .whitespaces) == when && self.remText.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.resetRem() }
            } else {
                self.whenBad = when
            }
            self.refresh()
        }
    }

    func save(_ at: Date, _ text: String, _ edit: Reminder?) {
        if let e = edit { a.reminders.move(e, to: at, text: text) } else { a.reminders.create(at: at, text: text) }
        refresh()
    }

    func resetRem() { remEdit = nil; remText = ""; remWhen = ""; refresh() }

    // Lists.
    func submitList() {
        let t = listAdd.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        listAdd = ""
        if listNew { listNew = false; if let n = a.lists.create(t) { listCur = n } }
        else if let c = listCur { a.lists.add(c, t) }
        refresh()
    }
}

struct ClawdPanelView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var model: AppModel
    var close: () -> Void
    var t: Theme { model.theme }
    var a: Assistant { model.assistant }

    var body: some View {
        let k = CGFloat(min(4, max(0.6, model.config.double("scale"))))
        Scaled(k: k) {
            content.frame(width: 300).scaleEffect(k, anchor: .topLeading)
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs.padding(.top, 6)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.top, 6).padding(.bottom, 8)
            switch state.tab {
            case "remind": RemindersPage(state: state, model: model)
            case "lists": ListsPage(state: state, model: model)
            default: chatPage
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(Color(hex: t.bg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .id(state.tick >= 0 ? 0 : 1)
    }

    var header: some View {
        HStack(spacing: 10) {
            Text("CLAWD  ·  v\(AppModel.version)").font(.system(size: 9.5, weight: .semibold)).foregroundColor(Color(hex: t.muted))
            Spacer()
            Text(advStamp).font(.system(size: 9)).foregroundColor(Color(hex: t.faint))
            if model.config.bool("showAdvisor") {
                icon("arrow.clockwise", T("adv.rescan")) { model.advisor.start(); state.refresh() }
            }
            if state.tab == "chat" && model.config.bool("showChat") {
                Text(T("chat.auto")).font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: model.config.bool("chatAutoRun") ? "#4ADE80" : t.faint))
                    .contentShape(Rectangle())
                    .onTapGesture { model.set("chatAutoRun", !model.config.bool("chatAutoRun")); state.refresh() }
                    .tip(model.config.bool("chatAutoRun") ? T("chat.autoOn") : T("chat.autoOff"))
                icon("plus", T("chat.new")) { a.reset(); state.refresh() }
            }
            icon("xmark", T("adv.close")) { close() }
        }
    }

    var advStamp: String {
        if model.advisor.scanning { return T("adv.checking") }
        if let at = model.advisor.at { return T("adv.checked", Fmt.clock(at)) }
        return ""
    }

    func icon(_ name: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: name).font(.system(size: 10, weight: .medium)).foregroundColor(Color(hex: t.muted))
            .contentShape(Rectangle()).onTapGesture(perform: action).tip(tip)
    }

    var tabs: some View {
        HStack(spacing: 14) {
            ForEach([("chat", T("tab.chat")), ("remind", T("tab.remind")), ("lists", T("tab.lists"))], id: \.0) { id, name in
                Text(name).font(.system(size: 10.5, weight: state.tab == id ? .semibold : .regular))
                    .foregroundColor(Color(hex: state.tab == id ? t.textHi : t.muted))
                    .contentShape(Rectangle())
                    .onTapGesture { state.tab = id; state.refresh() }
            }
            Spacer()
        }
    }

    // MARK: chat page

    var chatPage: some View {
        let tips = model.advisor.tips()
        let feed = a.feed
        return VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !tips.isEmpty {
                            Text(T("adv.tips")).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(hex: t.dim)).padding(.bottom, 4)
                            ForEach(tips, id: \.sig) { tip in TipCard(tip: tip, state: state, model: model) }
                        }
                        if model.config.bool("showChat") {
                            if !tips.isEmpty && !feed.isEmpty {
                                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.vertical, 6)
                            }
                            if feed.isEmpty {
                                Text(T("chat.hello")).font(.system(size: 9.5)).foregroundColor(Color(hex: t.muted)).padding(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(Array(feed.enumerated()), id: \.offset) { _, m in
                                ChatItem(msg: m, state: state, model: model)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.scrollToken) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            if model.config.bool("showChat") {
                if a.chatBusy || a.runBusy {
                    TimelineView(.periodic(from: .now, by: 0.35)) { ctx in
                        Text(busyText(ctx.date)).font(.system(size: 9.5)).foregroundColor(Color(hex: t.muted)).lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.top, 4)
                }
                inputRow.padding(.top, 6)
            }
        }
    }

    func busyText(_ now: Date) -> String {
        let dots = String(repeating: ".", count: 1 + Int(now.timeIntervalSince1970 * 3) % 3)
        if a.runBusy { return T("chat.running") + dots }
        let sec = Int(now.timeIntervalSince(a.chatStarted ?? now))
        return (a.doing.isEmpty ? T("chat.thinking") : a.doing) + dots + (sec >= 10 ? "  " + T("chat.sec", sec) : "")
    }

    var inputRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if state.input.isEmpty {
                    Text(state.tipRef != nil ? T("adv.refineHint") : state.hint.isEmpty ? T("chat.hint") : state.hint)
                        .font(.system(size: 10.5)).foregroundColor(Color(hex: t.faint)).padding(.horizontal, 6).padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
                TextField("", text: $state.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: t.text))
                    .lineLimit(1...5)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { state.input += "\n"; return .handled }
                        state.submitChat(); return .handled
                    }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: t.code)))
            Image(systemName: a.chatBusy ? "stop.circle.fill" : "paperplane.fill")
                .font(.system(size: 13)).foregroundColor(Color(hex: a.chatBusy ? Palette.crit : "#60A5FA"))
                .padding(.bottom, 4)
                .contentShape(Rectangle())
                .onTapGesture { if a.chatBusy { a.stop() } else { state.submitChat() } }
                .tip(a.chatBusy ? T("chat.stop") : "")
        }
    }
}

/// A tip: the text, a link to the right place, Do it / Refine / Dismiss.
struct TipCard: View {
    let tip: AdvisorTip
    @ObservedObject var state: PanelState
    let model: AppModel
    var t: Theme { model.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tip.text).font(.system(size: 10.5)).foregroundColor(Color(hex: t.text2)).fixedSize(horizontal: false, vertical: true)
            if let act = tip.act, let label = tip.actLabel {
                link(label, t.muted) { Open.url(act) }
            }
            HStack(spacing: 12) {
                if model.config.bool("showChat") {
                    link(T("adv.do"), "#4ADE80") { model.assistant.send(T("adv.doMsg", tip.text)) }
                    link(T("chat.refine"), "#60A5FA") { state.tipRef = tip.text; state.input = "" }
                }
                Spacer()
                link(T("adv.close"), t.dim) { model.advisor.dismiss(tip); state.refresh() }
            }
        }
        .modifier(Card(bg: t.card, edge: tip.warn ? Palette.warn : "#1AFFFFFF"))
    }

    func link(_ s: String, _ color: String, _ action: @escaping () -> Void) -> some View {
        Text(s).font(.system(size: 10)).foregroundColor(Color(hex: color)).contentShape(Rectangle()).onTapGesture(perform: action)
    }
}

struct Card: ViewModifier {
    var bg: String
    var edge: String = "#1AFFFFFF"
    func body(content: Content) -> some View {
        content
            .padding(EdgeInsets(top: 6, leading: 9, bottom: 7, trailing: 9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: bg)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(hex: edge), lineWidth: 1))
            .padding(.bottom, 6)
    }
}

/// Text with clickable links: bare http(s) addresses and markdown [text](url).
struct LinkedText: View {
    let text: String
    var size: CGFloat = 10.5
    var color: String

    var body: some View {
        Text(attributed).font(.system(size: size)).foregroundColor(Color(hex: color))
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in NSWorkspace.shared.open(url); return .handled })
    }

    var attributed: AttributedString {
        let rx = try! NSRegularExpression(pattern: #"\[([^\]\r\n]+)\]\((https?://[^\s)]+)\)|https?://[^\s<>"'`\[\]]+"#)
        let ns = text as NSString
        var out = AttributedString()
        var at = 0
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var label = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
            var url = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range)
            var tail = ""
            // "see https://x.com/a." - the full stop stays text.
            while label.isEmpty, let c = url.last, ".,;:!?»”'\"".contains(c) || (c == ")" && url.filter { $0 == "(" }.count < url.filter { $0 == ")" }.count) {
                tail = String(c) + tail; url.removeLast()
            }
            if label.isEmpty { label = url }
            guard let u = URL(string: url) else { continue }
            if m.range.location > at { out += AttributedString(ns.substring(with: NSRange(location: at, length: m.range.location - at))) }
            var link = AttributedString(label)
            link.link = u
            link.foregroundColor = Color(hex: "#60A5FA")
            out += link
            out += AttributedString(tail)
            at = m.range.location + m.range.length
        }
        if at < ns.length { out += AttributedString(ns.substring(from: at)) }
        return out
    }
}

struct ChatItem: View {
    let msg: ChatMessage
    @ObservedObject var state: PanelState
    let model: AppModel
    @State private var hover = false
    @State private var copied = false
    var t: Theme { model.theme }
    var a: Assistant { model.assistant }

    var copyText: String { [msg.text, msg.run?.script ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n") }

    var body: some View {
        Group {
            switch msg.role {
            case "user":
                HStack { Spacer(minLength: 36); bubble(bg: t.card2) { textBox } }
            case "remind":
                bubble(bg: t.card, edge: "#D77757") { LinkedText(text: "⏰ \(msg.text)", color: t.textHi) }
            case "note":
                LinkedText(text: msg.text, size: 9.5, color: t.muted).padding(.horizontal, 4).padding(.bottom, 6)
            default:
                HStack {
                    bubble(bg: t.card) {
                        VStack(alignment: .leading, spacing: 0) {
                            if msg.remote == true { textBox } else {
                                if !msg.text.isEmpty { LinkedText(text: msg.text, color: t.text2) }
                                if msg.run != nil { runBlock }
                                if msg.act != nil { actBlock }
                                if msg.grant != nil { grantBlock }
                            }
                        }
                    }
                    Spacer(minLength: 24)
                }
            }
        }
        .contextMenu { if !copyText.isEmpty { Button(T("chat.copy")) { copy() } } }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    @ViewBuilder var textBox: some View {
        if msg.remote == true {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "iphone").font(.system(size: 8.5))
                    Text("\(T("chat.remoteTag"))  \(Fmt.clock(msg.at))").font(.system(size: 8.5))
                }
                .foregroundColor(Color(hex: t.dim))
                LinkedText(text: msg.text, color: t.text2)
            }
        } else {
            LinkedText(text: msg.text, color: t.text2)
        }
    }

    func bubble<C: View>(bg: String, edge: String = "#1AFFFFFF", @ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(.trailing, 12)
            .modifier(Card(bg: bg, edge: edge))
            .overlay(alignment: .topTrailing) {
                if hover && !copyText.isEmpty {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9))
                        .foregroundColor(Color(hex: copied ? Palette.ok : t.muted))
                        .padding(5).contentShape(Rectangle()).onTapGesture { copy() }.tip(T("chat.copy"))
                }
            }
            .onHover { hover = $0 }
    }

    func code(_ s: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(s).font(.system(size: 9.5, design: .monospaced)).foregroundColor(Color(hex: t.text3))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120).fixedSize(horizontal: false, vertical: true)
        .padding(EdgeInsets(top: 4, leading: 5, bottom: 4, trailing: 5))
        .background(Color(hex: t.code))
    }

    func link(_ s: String, _ color: String, _ action: @escaping () -> Void) -> some View {
        Text(s).font(.system(size: 10)).foregroundColor(Color(hex: color)).contentShape(Rectangle()).onTapGesture(perform: action)
    }

    var runBlock: some View {
        let run = msg.run!
        return VStack(alignment: .leading, spacing: 5) {
            code(run.script).padding(.top, 5)
            HStack(spacing: 12) {
                switch run.state {
                case "pending":
                    link(T("chat.run"), "#4ADE80") { a.startRun(msg) }
                    link(T("chat.refine"), "#60A5FA") { state.hint = T("chat.refineHint") }
                    link(T("chat.skip"), t.dim) { a.setRunState(msg, "skipped") }
                case "running":
                    Text(T("chat.state.running")).font(.system(size: 10)).foregroundColor(Color(hex: Palette.warn))
                case "done":
                    Text(T("chat.state.done", run.code.map { Int($0) } ?? -1)).font(.system(size: 10))
                        .foregroundColor(Color(hex: run.code == 0 ? Palette.ok : Palette.crit))
                default:
                    Text(T("chat.state.\(run.state)")).font(.system(size: 10)).foregroundColor(Color(hex: t.dim))
                }
            }
        }
    }

    var actBlock: some View {
        let act = msg.act!
        return VStack(alignment: .leading, spacing: 3) {
            Text(T("chat.actHead")).font(.system(size: 9.5)).foregroundColor(Color(hex: t.muted))
            code(act.calls.map { "\($0.tool.replacingOccurrences(of: "mcp__", with: "")) \($0.input)" }.joined(separator: "\n"))
            HStack(spacing: 12) {
                if act.state == "pending" {
                    link(T("chat.run"), "#4ADE80") { a.approveAct(msg) }
                    link(T("chat.skip"), t.dim) { a.setActState(msg, "skipped") }
                } else {
                    Text(T("chat.act.\(act.state)")).font(.system(size: 10)).foregroundColor(Color(hex: t.dim))
                }
            }
        }
        .padding(.top, 4)
    }

    var grantBlock: some View {
        let g = msg.grant!
        return VStack(alignment: .leading, spacing: 3) {
            Text(T("task.grantHead", g.task)).font(.system(size: 9.5)).foregroundColor(Color(hex: t.muted))
            code(g.rules.joined(separator: "\n"))
            HStack(spacing: 12) {
                if g.state == "pending" {
                    link(T("task.grant"), "#4ADE80") { a.grant(msg) }
                    link(T("chat.skip"), t.dim) { a.setGrantState(msg, "skipped") }
                } else {
                    Text(T("task.grant.\(g.state)")).font(.system(size: 10)).foregroundColor(Color(hex: t.dim))
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Reminders tab: what is coming, the add/change form, recurring tasks, recently fired.
struct RemindersPage: View {
    @ObservedObject var state: PanelState
    @ObservedObject var model: AppModel
    var t: Theme { model.theme }
    var a: Assistant { model.assistant }

    var body: some View {
        let rem = a.reminders.all()
        let done = a.reminders.done(count: 5)
        let tasks = model.config.bool("showTasks") ? a.tasks() : []
        let st = a.taskState()
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if rem.isEmpty {
                        Text(T("rem.none")).font(.system(size: 10)).foregroundColor(Color(hex: t.muted)).padding(.leading, 2).padding(.bottom, 4)
                    }
                    ForEach(rem, id: \.path) { r in remCard(r) }
                    if !tasks.isEmpty {
                        Text(T("task.head")).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(hex: t.dim)).padding(.vertical, 4)
                        ForEach(tasks, id: \.name) { tk in taskRow(tk, st[tk.name]) }
                    }
                    if !done.isEmpty {
                        Text(T("rem.done")).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(hex: t.dim)).padding(.top, 4)
                        ForEach(Array(done.enumerated()), id: \.offset) { _, d in
                            HStack {
                                Text("\(ReminderStore.formatTime(d.at))  ·  \(d.text)").font(.system(size: 10)).foregroundColor(Color(hex: t.dim))
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer()
                                Text(T("rem.again")).font(.system(size: 10)).foregroundColor(Color(hex: "#60A5FA"))
                                    .onTapGesture { state.remText = d.text }
                            }
                            .padding(.top, 3)
                        }
                    }
                }
            }
            .frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
            form.padding(.top, 8)
        }
    }

    func link(_ s: String, _ color: String, _ action: @escaping () -> Void) -> some View {
        Text(s).font(.system(size: 10)).foregroundColor(Color(hex: color)).contentShape(Rectangle()).onTapGesture(perform: action)
    }

    func remCard(_ r: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(ReminderStore.formatTime(r.at) + (r.repeatRule.isEmpty ? "" : "  ↻ \(T("rem.\(r.repeatRule)"))"))
                    .font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: t.textHi))
                Spacer()
                if let left = Fmt.span(to: r.at) { Text(T("rem.in", left)).font(.system(size: 9.5)).foregroundColor(Color(hex: t.dim)) }
            }
            LinkedText(text: r.text, color: t.text2)
            HStack(spacing: 12) {
                link(T("rem.edit"), "#60A5FA") {
                    state.remEdit = r; state.remText = r.text
                    let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"; state.remWhen = f.string(from: r.at)
                }
                link(T("rem.later"), t.muted) {
                    // Later from now if it is due already, from its time otherwise.
                    a.reminders.move(r, to: max(r.at, Date()).addingTimeInterval(3600)); state.refresh()
                }
                link(T("rem.delete"), t.dim) {
                    try? FileManager.default.removeItem(at: r.path)
                    if state.remEdit?.path == r.path { state.resetRem() } else { state.refresh() }
                }
            }
            .padding(.top, 2)
        }
        .modifier(Card(bg: t.card))
    }

    func taskRow(_ tk: ClawdTask, _ st: Assistant.TaskStateEntry?) -> some View {
        var info = [tk.whenText]
        if let h = tk.hours, tk.at == nil { info.append("\(h.0)-\(h.1)") }
        let running = a.runningTask == tk.name, queued = a.isQueued(tk.name)
        if running { info.append(T("task.running")) }
        else if queued { info.append(T("task.queued")) }
        else if let l = st?.last { info.append(T("task.last", ReminderStore.formatTime(l))) }
        if tk.paused { info.append(T("task.paused")) }
        if !tk.paused, let w = a.budgetWait(tk) { info.append(T("task.budget", w)) }
        if !tk.badTools.isEmpty { info.append(T("task.badTools", tk.badTools.joined(separator: " "))) }
        let open = state.taskOpen == tk.name
        let err = st?.error ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(open ? "▾" : "▸") \(tk.name)  ·  \(info.joined(separator: "  ·  "))").font(.system(size: 10))
                .foregroundColor(Color(hex: !err.isEmpty ? Palette.warn : tk.paused ? t.dim : t.text2))
                .contentShape(Rectangle())
                .onTapGesture { state.taskOpen = open ? nil : tk.name }
                .tip(err)
            HStack(spacing: 12) {
                if !running && !queued { link(T("task.now"), "#60A5FA") { a.requestRun(tk); state.refresh() } }
                link(tk.paused ? T("task.resume") : T("task.pause"), t.muted) { a.setPaused(tk, !tk.paused) }
                link(T("task.open"), t.muted) { Open.file(tk.path) }
                link(T("rem.delete"), t.dim) { a.removeTask(tk.name) }
            }
            if open {
                var hist = (st?.history ?? []).map { ($0.at, $0.text, $0.told ? t.text4 : t.dim) }
                let _ = !err.isEmpty ? hist.append((st?.last ?? Date(), T("task.lastError", err), Palette.warn)) : ()
                if hist.isEmpty { Text(T("task.noReports")).font(.system(size: 9.5)).foregroundColor(Color(hex: t.dim)).padding(.top, 2) }
                ForEach(Array(hist.sorted { $0.0 > $1.0 }.enumerated()), id: \.offset) { _, h in
                    Text("\(ReminderStore.formatTime(h.0))  ·  \(h.1)").font(.system(size: 9.5)).foregroundColor(Color(hex: h.2))
                        .lineLimit(1).truncationMode(.tail).tip(h.1)
                }
            }
        }
        .modifier(Card(bg: t.card))
    }

    var form: some View {
        VStack(alignment: .leading, spacing: 4) {
            field($state.remText, T("rem.textHint"))
            field($state.remWhen, T("rem.whenHint"))
            if let p = state.parsedWhen {
                Text(p.0).font(.system(size: 9.5)).foregroundColor(Color(hex: p.1))
            }
            HStack(spacing: 10) {
                ForEach(TA("rem.chips"), id: \.self) { c in link(c, t.muted) { state.remWhen = c } }
                if state.remEdit != nil { link(T("rem.cancel"), t.dim) { state.resetRem() } }
                Spacer()
                Text(state.remEdit != nil ? T("rem.save") : T("rem.add")).font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#60A5FA")).contentShape(Rectangle()).onTapGesture { state.saveReminder() }
            }
        }
    }

    func field(_ b: Binding<String>, _ hint: String) -> some View {
        TextField("", text: b, prompt: Text(hint).foregroundColor(Color(hex: t.faint)))
            .textFieldStyle(.plain).font(.system(size: 10.5)).foregroundColor(Color(hex: t.text))
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: t.code)))
            .onSubmit { state.saveReminder() }
            .onExitCommand { if state.remEdit != nil { state.resetRem() } }
    }
}

/// Lists tab: shopping and any other, with checkboxes.
struct ListsPage: View {
    @ObservedObject var state: PanelState
    @ObservedObject var model: AppModel
    var t: Theme { model.theme }
    var l: ListStore { model.assistant.lists }

    var body: some View {
        let names = l.names()
        let cur = state.listCur.flatMap { names.contains($0) ? $0 : nil } ?? names.first
        let list = cur.map { l.read($0) }
        VStack(alignment: .leading, spacing: 6) {
            FlowChips(items: names.map { n in
                let open = l.read(n).items.filter { !$0.done }.count
                return (n, open > 0 ? "\(n)  \(open)" : n, n == cur && !state.listNew)
            } + [("+", "+", state.listNew)], theme: t) { id in
                if id == "+" { state.listNew = true } else { state.listCur = id; state.listNew = false }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    if let list, !list.items.isEmpty, let cur {
                        ForEach(list.items.filter { !$0.done } + list.items.filter(\.done), id: \.idx) { it in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: it.done ? "checkmark.square.fill" : "square").font(.system(size: 11))
                                    .foregroundColor(Color(hex: it.done ? Palette.ok : t.muted))
                                Text(it.text).font(.system(size: 10.5)).strikethrough(it.done)
                                    .foregroundColor(Color(hex: it.done ? t.dim : t.text))
                                Spacer()
                                Text("✕").font(.system(size: 9)).foregroundColor(Color(hex: t.faint))
                                    .onTapGesture { l.removeItem(cur, it.idx); state.refresh() }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { l.setDone(cur, it.idx, !it.done); state.refresh() }
                        }
                    } else {
                        Text(T("list.empty")).font(.system(size: 10)).foregroundColor(Color(hex: t.muted)).padding(.leading, 2)
                    }
                }
            }
            .frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
            TextField("", text: $state.listAdd, prompt: Text(state.listNew ? T("list.newHint") : T("list.addHint")).foregroundColor(Color(hex: t.faint)))
                .textFieldStyle(.plain).font(.system(size: 10.5)).foregroundColor(Color(hex: t.text))
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: t.code)))
                .onSubmit { if state.listCur == nil { state.listCur = cur }; state.submitList() }
                .onExitCommand { state.listNew = false; state.listAdd = "" }
            HStack(spacing: 12) {
                if let list, list.items.contains(where: \.done), let cur {
                    Text(T("list.clear")).font(.system(size: 10)).foregroundColor(Color(hex: t.muted))
                        .onTapGesture { l.clearDone(cur); state.refresh() }
                }
                // Only an empty list can go - nothing is lost by a stray click.
                if let list, list.items.isEmpty, let cur {
                    Text(T("list.delete")).font(.system(size: 10)).foregroundColor(Color(hex: t.dim))
                        .onTapGesture { l.remove(cur); state.listCur = nil; state.refresh() }
                }
            }
        }
    }
}

struct FlowChips: View {
    let items: [(id: String, label: String, on: Bool)]
    let theme: Theme
    let tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.id) { it in
                Text(it.label).font(.system(size: 10)).foregroundColor(Color(hex: it.on ? theme.textHi : theme.muted))
                    .padding(EdgeInsets(top: 2, leading: 8, bottom: 3, trailing: 8))
                    .background(Capsule().fill(Color(hex: it.on ? theme.card2 : theme.card)))
                    .contentShape(Capsule())
                    .onTapGesture { tap(it.id) }
            }
        }
    }
}

/// Wraps children onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += row + 4; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: maxW, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += row + 4; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}
