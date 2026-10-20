import ClawdCore
import SwiftUI

/// Right-click Clawd: developer mode. A forced state holds until "Auto".
struct DevMenu: View {
    let model: AppModel
    var m: MascotEngine { model.mascot }

    var body: some View {
        Text(T("mm.head"))
        Divider()
        Button(T("mm.auto")) { m.backToAuto(); model.sky.forcePhase = nil; model.sky.forceCode = nil }
        Menu(T("mm.state")) {
            ForEach(Mood.allCases, id: \.self) { mood in
                Button(T("mood.\(mood.rawValue)")) { m.setForce(mood) }
            }
        }
        Menu(T("mm.anim")) {
            ForEach(MascotData.shared.actOrder, id: \.self) { a in
                Button(T("act.\(a)")) { m.startAct(a) }
            }
        }
        Toggle(T("mm.sweat"), isOn: Binding(get: { m.forceCrit }, set: { m.setForceCrit($0) }))
        Menu(T("mm.hearts")) {
            Button(T("mm.byLimit")) { m.forceHearts = nil }
            ForEach([(6, "3"), (5, "2½"), (4, "2"), (3, "1½"), (2, "1"), (1, "½"), (0, "0")], id: \.0) { h in
                Button(h.1) { m.forceHearts = h.0 }
            }
            Divider()
            Button(T("mm.drain")) { m.startDrain() }
        }
        if model.config.bool("showSky") {
            Menu(T("mm.sky")) {
                Button(T("mm.byClock")) { model.sky.forcePhase = nil }
                ForEach(SkyEngine.phases, id: \.self) { p in Button(T("phase.\(p)")) { model.sky.forcePhase = p } }
                Divider()
                Button(T("mm.wxLive")) { model.sky.forceCode = nil }
                ForEach(WeatherKind.demoCodes, id: \.self) { c in Button(WeatherKind.of(c).name) { model.sky.forceCode = c } }
            }
        }
        Divider()
        Button(T("mm.demo")) { m.startDemo() }
    }
}
