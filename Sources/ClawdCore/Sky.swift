import Foundation

/// A colour with alpha, 0...255 per channel. Parses "#RRGGBB" and "#AARRGGBB".
public struct RGBA: Equatable {
    public var a, r, g, b: Double
    public init(a: Double = 255, r: Double, g: Double, b: Double) { self.a = a; self.r = r; self.g = g; self.b = b }
    public init(_ hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        if s.count == 8 {
            a = Double((v >> 24) & 0xFF); r = Double((v >> 16) & 0xFF); g = Double((v >> 8) & 0xFF); b = Double(v & 0xFF)
        } else {
            a = 255; r = Double((v >> 16) & 0xFF); g = Double((v >> 8) & 0xFF); b = Double(v & 0xFF)
        }
    }
    public static func mix(_ x: RGBA, _ y: RGBA, _ k0: Double) -> RGBA {
        let k = min(1, max(0, k0))
        return RGBA(a: x.a + (y.a - x.a) * k, r: x.r + (y.r - x.r) * k, g: x.g + (y.g - x.g) * k, b: x.b + (y.b - x.b) * k)
    }
    /// Cloudiness: the colour fades toward grey and darkens.
    public func dimmed(_ g0: Double) -> RGBA {
        let l = 0.3 * r + 0.59 * g + 0.11 * b
        let f = 1 - 0.3 * g0
        return RGBA(a: a, r: (r + (l - r) * g0) * f, g: (g + (l - g) * g0) * f, b: (b + (l - b) * g0) * f)
    }
}

/// WMO weather codes grouped into what the sky draws. Three codes in a group: light, moderate, heavy.
public struct WeatherKind {
    public var id: String
    public var cover: Double
    public var fog = false, storm = false
    public var rain = 0, snow = 0
    public var name: String { TD("wx.\(id)", default: id) }

    static let table: [([Int], String, Double, Int, Int, Bool, Bool)] = [
        ([0], "clear", 0, 0, 0, false, false), ([1], "mostlyClear", 0.2, 0, 0, false, false),
        ([2], "partly", 0.5, 0, 0, false, false), ([3], "overcast", 0.85, 0, 0, false, false),
        ([45, 48], "fog", 0.7, 0, 0, true, false), ([51, 53, 55], "drizzle", 0.8, 6, 0, false, false),
        ([56, 57], "iceDrizzle", 0.8, 6, 0, false, false), ([61, 63, 65], "rain", 0.9, 12, 0, false, false),
        ([66, 67], "iceRain", 0.9, 12, 0, false, false), ([71, 73, 75], "snow", 0.85, 0, 10, false, false),
        ([77], "grains", 0.85, 0, 8, false, false), ([80, 81, 82], "showers", 0.85, 16, 0, false, false),
        ([85, 86], "snowShowers", 0.9, 0, 14, false, false), ([95, 96, 99], "storm", 1.0, 16, 0, false, true),
    ]
    public static let demoCodes = [0, 2, 3, 45, 53, 63, 82, 73, 95]

    public static func of(_ code: Int) -> WeatherKind {
        for (codes, id, cover, rain, snow, fog, storm) in table {
            guard let i = codes.firstIndex(of: code) else { continue }
            let mul = codes.count == 3 ? [0.6, 1.0, 1.35][i] : 1.0
            return WeatherKind(id: id, cover: cover, fog: fog, storm: storm,
                               rain: Int((Double(rain) * mul).rounded()), snow: Int((Double(snow) * mul).rounded()))
        }
        return WeatherKind(id: "code", cover: 0.5)
    }
}

public struct Weather {
    public var code: Int
    public var temp: Double
    public var wind: Double          // km/h
    public var sunrise: Double?      // minutes from local midnight
    public var sunset: Double?
    public var at: Date
}

public enum Astronomy {
    /// Sunrise and sunset (NOAA), local minutes from midnight.
    public static func sun(lat: Double, lon: Double, now: Date = Date()) -> (sr: Double, ss: Double) {
        let doy = Double(Calendar.current.ordinality(of: .day, in: .year, for: now) ?? 1)
        let gm = 2 * Double.pi / 365 * (doy - 0.5)
        let eq = 229.18 * (0.000075 + 0.001868 * cos(gm) - 0.032077 * sin(gm) - 0.014615 * cos(2 * gm) - 0.040849 * sin(2 * gm))
        let dec = 0.006918 - 0.399912 * cos(gm) + 0.070257 * sin(gm) - 0.006758 * cos(2 * gm) + 0.000907 * sin(2 * gm)
            - 0.002697 * cos(3 * gm) + 0.00148 * sin(3 * gm)
        let la = lat * .pi / 180
        var c = cos(90.833 * .pi / 180) / (cos(la) * cos(dec)) - tan(la) * tan(dec)
        c = max(-0.999, min(0.999, c))   // polar day or night
        let ha = acos(c) * 180 / .pi
        let tz = Double(TimeZone.current.secondsFromGMT(for: now)) / 60
        func norm(_ v: Double) -> Double { (v.truncatingRemainder(dividingBy: 1440) + 1440).truncatingRemainder(dividingBy: 1440) }
        return (norm(720 - 4 * (lon + ha) - eq + tz), norm(720 - 4 * (lon - ha) - eq + tz))
    }

    public static let moonMonth = 29.530588853

    /// Moon age in days, from the Moon-Sun elongation with the main periodic terms.
    public static func moonAge(_ now: Date = Date()) -> Double {
        let epoch = Date(timeIntervalSince1970: 946_728_000)   // 2000-01-01 12:00 UTC
        let d = now.timeIntervalSince(epoch) / 86400
        let rad = Double.pi / 180
        let g = (357.528 + 0.9856003 * d) * rad
        let sunL = 280.460 + 0.9856474 * d + 1.915 * sin(g) + 0.020 * sin(2 * g)
        let lm = 218.316 + 13.176396 * d
        let mm = (134.963 + 13.064993 * d) * rad
        let dd = (lm - (280.460 + 0.9856474 * d)) * rad
        let moon = lm + 6.289 * sin(mm) - 1.274 * sin(2 * dd - mm) + 0.658 * sin(2 * dd) - 0.186 * sin(g)
            - 0.059 * sin(2 * dd - 2 * mm) - 0.057 * sin(2 * dd - mm - g)
        let e = ((moon - sunL).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return e / 360 * moonMonth
    }

    /// Phase index 0..7 (new moon round to waning crescent) and percent lit.
    public static func moonInfo(_ now: Date = Date()) -> (name: Int, lit: Int) {
        let f = moonAge(now) / moonMonth
        return (Int(floor(f * 8 + 0.5)) % 8, Int(((1 - cos(2 * .pi * f)) / 2 * 100).rounded()))
    }

    /// 7x7 moon pixels: lit and dark, as rows of "#" and ".".
    public static func moonPixels(age: Double, lat: Double) -> (lit: [String], dark: [String]) {
        let th = 2 * Double.pi * age / moonMonth
        let k = cos(th)
        let n = 7, r = 3.5
        var lit: [String] = [], dark: [String] = []
        for y in 0..<n {
            var a = "", b = ""
            for x in 0..<n {
                var u = (Double(x) + 0.5 - r) / r
                let v = (Double(y) + 0.5 - r) / r
                if lat < 0 { u = -u }   // in the southern hemisphere the waxing moon is on the left
                let inside = u * u + v * v <= 1.05
                let t = k * sqrt(max(0, 1 - v * v))
                let on = inside && (th < .pi ? u > t : u < -t)
                a += on ? "#" : "."; b += inside && !on ? "#" : "."
            }
            lit.append(a); dark.append(b)
        }
        return (lit, dark)
    }
}

/// Location (by IP once per run, or from config) and weather (Open-Meteo, falling back to met.no).
public final class WeatherProbe {
    public private(set) var geo: (lat: Double, lon: Double, city: String?)?
    public private(set) var weather: Weather?
    public var tried = Date.distantPast
    private var geoTried = Date.distantPast
    private var alt = false
    private var busy = false
    public init() {}

    public func place(config: Config) -> (lat: Double, lon: Double, city: String?)? {
        if let la = config.optDouble("weatherLat"), let lo = config.optDouble("weatherLon") { return (la, lo, nil) }
        return geo
    }

    public func start(config: Config) {
        guard !busy else { return }
        guard let p = place(config: config) else {
            guard Date().timeIntervalSince(geoTried) > 600 else { return }
            geoTried = Date(); busy = true
            HTTP.get("https://ipwho.is/?lang=\(I18n.lang)") { [weak self] d in
                guard let self else { return }
                self.busy = false
                if let d, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                   (j["success"] as? Bool) != false, let la = (j["latitude"] as? NSNumber)?.doubleValue,
                   let lo = (j["longitude"] as? NSNumber)?.doubleValue {
                    self.geo = (la, lo, j["city"] as? String)
                    self.tried = .distantPast
                }
            }
            return
        }
        tried = Date(); busy = true
        let url: String
        if alt {
            url = String(format: "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=%.4f&lon=%.4f", p.lat, p.lon)
        } else {
            url = "https://api.open-meteo.com/v1/forecast?latitude=\(p.lat)&longitude=\(p.lon)"
                + "&current=weather_code,temperature_2m,wind_speed_10m&daily=sunrise,sunset&timezone=auto&forecast_days=1"
        }
        let useAlt = alt
        HTTP.get(url) { [weak self] d in
            guard let self else { return }
            self.busy = false
            let j = d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if useAlt { if let j, let w = Self.fromMetNo(j) { self.weather = w }; return }
            guard let j, let w = Self.fromOpenMeteo(j) else {
                // Open-Meteo is unreachable (sometimes blocked) - ask met.no from now on.
                self.alt = true; self.tried = .distantPast; return
            }
            self.weather = w
        }
    }

    public static func fromOpenMeteo(_ j: [String: Any]) -> Weather? {
        guard let cur = j["current"] as? [String: Any], let code = (cur["weather_code"] as? NSNumber)?.intValue else { return nil }
        var w = Weather(code: code, temp: (cur["temperature_2m"] as? NSNumber)?.doubleValue ?? 0,
                        wind: (cur["wind_speed_10m"] as? NSNumber)?.doubleValue ?? 0, sunrise: nil, sunset: nil, at: Date())
        let daily = j["daily"] as? [String: Any]
        func mins(_ s: String?) -> Double? {
            guard let s, let t = s.split(separator: "T").last else { return nil }
            let hm = t.split(separator: ":").compactMap { Double($0) }
            return hm.count >= 2 ? hm[0] * 60 + hm[1] : nil
        }
        w.sunrise = mins((daily?["sunrise"] as? [String])?.first)
        w.sunset = mins((daily?["sunset"] as? [String])?.first)
        return w
    }

    /// met.no describes weather with a word: "lightrainshowers_day" -> WMO code.
    public static func fromMetNo(_ j: [String: Any]) -> Weather? {
        guard let ts = (j["properties"] as? [String: Any])?["timeseries"] as? [[String: Any]],
              let data = ts.first?["data"] as? [String: Any] else { return nil }
        let sym = (((data["next_1_hours"] as? [String: Any])?["summary"] as? [String: Any])?["symbol_code"] as? String ?? "")
            .replacingOccurrences(of: #"_(day|night|polartwilight)$"#, with: "", options: .regularExpression)
        let lvl = sym.hasPrefix("light") ? 0 : sym.hasPrefix("heavy") ? 2 : 1
        let shw = sym.contains("showers")
        let code: Int
        if sym.contains("thunder") { code = 95 }
        else if sym.contains("snow") { code = shw ? [85, 85, 86][lvl] : [71, 73, 75][lvl] }
        else if sym.contains("sleet") { code = lvl == 2 ? 67 : 66 }
        else if sym.contains("rain") { code = shw ? [80, 81, 82][lvl] : [61, 63, 65][lvl] }
        else if sym.hasPrefix("fog") { code = 45 }
        else if sym.hasPrefix("cloudy") { code = 3 }
        else if sym.hasPrefix("partlycloudy") { code = 2 }
        else if sym.hasPrefix("fair") { code = 1 }
        else if sym.hasPrefix("clearsky") { code = 0 }
        else { code = 3 }
        let det = (data["instant"] as? [String: Any])?["details"] as? [String: Any]
        return Weather(code: code, temp: (det?["air_temperature"] as? NSNumber)?.doubleValue ?? 0,
                       wind: 3.6 * ((det?["wind_speed"] as? NSNumber)?.doubleValue ?? 0), sunrise: nil, sunset: nil, at: Date())
    }
}

/// Everything the sky view draws in one frame (points inside the sky area).
public struct SkyRender {
    public var top = RGBA("#00304A8C"), bottom = RGBA("#1A304A8C")
    public var sun: (x: Double, y: Double, color: RGBA, opacity: Double)?
    public var moon: (x: Double, y: Double, lit: [String], dark: [String], opacity: Double)?
    public var stars: [(x: Double, y: Double, opacity: Double)] = []
    public var clouds: [(x: Double, y: Double, shape: Int, opacity: Double)] = []
    public var cloudColor = RGBA("#B4B4BC")
    public var fog: [(x: Double, y: Double, w: Double, opacity: Double)] = []
    public var drops: [(x: Double, y: Double)] = []
    public var flakes: [(x: Double, y: Double)] = []
    public var ground: RGBA?
    public var flash = 0.0
    public init() {}
}

/// The sky's animation state (upstream lib/sky.ps1).
public final class SkyEngine {
    public static let cloudShapes: [[String]] = [
        ["....###.....", "..#######...", ".##########.", "############"],
        ["..###...", ".######.", "########"],
        ["...##.##..", ".########.", "##########"],
    ]
    public static let sunArt = ["..###..", ".#####.", "#######", "#######", "#######", ".#####.", "..###.."]
    public static let moonPx = 1.3, sunPx = 1.4

    static let pal: [String: (top: RGBA, bottom: RGBA, light: Double)] = [
        "night": (RGBA("#00304A8C"), RGBA("#1A304A8C"), 0),
        "dawn": (RGBA("#00404E8A"), RGBA("#33E08A66"), 0.5),
        "day": (RGBA("#004A8CCB"), RGBA("#2E6FA8D8"), 1),
        "dusk": (RGBA("#00383070"), RGBA("#33D86A50"), 0.5),
    ]
    public static let phases = ["dawn", "day", "dusk", "night"]

    public var forcePhase: String?
    public var forceCode: Int?
    var tick = 0
    var stars: [(fx: Double, fy: Double)] = (0..<20).map { _ in (Double.random(in: 0..<1), Double.random(in: 0..<0.6)) }
    var clouds: [(x: Double, fy: Double, v: Double, fade: Double)] = (0..<9).map { _ in (-1, 0.05 + 0.3 * Double.random(in: 0..<1), 0.7 + 0.6 * Double.random(in: 0..<1), 0) }
    var fog: [(x: Double, fy: Double)] = (0..<3).map { (Double.random(in: 0..<1), 0.42 + 0.2 * Double($0)) }
    var drops: [(x: Double, y: Double, v: Double)] = Array(repeating: (0, -99, 0), count: 40)
    var flakes: [(x: Double, y: Double, v: Double, ph: Double)] = Array(repeating: (0, -99, 0, 0), count: 34)
    var flash = 0
    public init() {}

    public func sunTimes(weather: Weather?, place: (lat: Double, lon: Double, city: String?)?) -> (sr: Double, ss: Double) {
        if let w = weather, let sr = w.sunrise, let ss = w.sunset { return (sr, ss) }
        if let p = place { return Astronomy.sun(lat: p.lat, lon: p.lon) }
        return (420, 1140)
    }

    /// Weather to draw: forced from developer mode, or fresh (no older than 3 hours).
    public func skyWeather(_ w: Weather?) -> (code: Int, wind: Double)? {
        if let c = forceCode { return (c, 12) }
        if let w, Date().timeIntervalSince(w.at) < 3 * 3600 { return (w.code, w.wind) }
        return nil
    }

    public func step(width w: Double, height h: Double, weather: Weather?,
                     place: (lat: Double, lon: Double, city: String?)?, now: Date = Date()) -> SkyRender {
        tick += 1
        var r = SkyRender()
        guard w > 0, h > 0 else { return r }
        let st = sunTimes(weather: weather, place: place)
        let sr = st.sr, ss = st.ss
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        var t = Double(comps.hour ?? 0) * 60 + Double(comps.minute ?? 0) + Double(comps.second ?? 0) / 60
        switch forcePhase {
        case "dawn": t = sr - 10
        case "day": t = (sr + ss) / 2
        case "dusk": t = ss + 10
        case "night": t = 0
        default: break
        }
        let wx = skyWeather(weather)
        let code = wx?.code ?? 0, wind = wx?.wind ?? 8
        let kind = WeatherKind.of(code)

        let stops: [(Double, String)] = [(sr - 80, "night"), (sr - 10, "dawn"), (sr + 70, "day"), (ss - 70, "day"), (ss + 10, "dusk"), (ss + 80, "night")]
        var a = Self.pal["night"]!, b = Self.pal["night"]!, k = 0.0
        for i in 0..<(stops.count - 1) where t >= stops[i].0 && t < stops[i + 1].0 {
            a = Self.pal[stops[i].1]!; b = Self.pal[stops[i + 1].1]!
            k = (t - stops[i].0) / (stops[i + 1].0 - stops[i].0)
            break
        }
        let light = a.light + (b.light - a.light) * k
        let g = kind.cover * 0.9
        r.top = RGBA.mix(a.top, b.top, k).dimmed(g)
        r.bottom = RGBA.mix(a.bottom, b.bottom, k).dimmed(g)
        if kind.snow > 0 { r.ground = RGBA.mix(RGBA("#50A1A8B5"), RGBA("#80DDE4EC"), light) }
        var cc = RGBA.mix(RGBA("#5E5E68"), RGBA("#B4B4BC"), light)
        if kind.rain > 0 || kind.storm { cc = RGBA.mix(cc, RGBA("#52525B"), 0.55) }
        r.cloudColor = cc

        func onArc(_ p: Double) -> (Double, Double)? {
            guard p >= -0.06, p <= 1.06 else { return nil }
            let alt = sin(.pi * p)
            return (7 + p * (w - 14), h + 3 - alt * (h - 12))
        }
        let vis = max(0, 1 - kind.cover * 1.15)
        let p = (t - sr) / (ss - sr)
        if vis > 0, let (sx, sy) = onArc(p) {
            r.sun = (sx, sy, RGBA.mix(RGBA("#FB923C"), RGBA("#FDE68A"), sin(.pi * p) * 1.6), vis)
        }
        let q = ((t - ss + 1440).truncatingRemainder(dividingBy: 1440)) / (sr + 1440 - ss)
        if vis > 0, let (mx, my) = onArc(q) {
            let px = Astronomy.moonPixels(age: Astronomy.moonAge(now), lat: place?.lat ?? 50)
            r.moon = (mx, my, px.lit, px.dark, vis)
        }
        let starOp = (1 - light * 2) * max(0, 1 - kind.cover * 1.4)
        if starOp > 0 {
            for (i, s) in stars.enumerated() {
                r.stars.append(((s.fx * (w - 2)).rounded(), (2 + s.fy * h).rounded(), starOp * (0.55 + 0.45 * sin(Double(tick) / 7 + Double(i) * 1.7))))
            }
        }
        let dens = max(1, w / 140)
        let nClouds = min(clouds.count, Int((kind.cover * 5 * dens).rounded()))
        let nRain = min(drops.count, Int((Double(kind.rain) * dens).rounded()))
        let nSnow = min(flakes.count, Int((Double(kind.snow) * dens).rounded()))

        let drift = 0.04 + wind / 350
        for i in clouds.indices {
            var c = clouds[i]
            let cw = Double(Self.cloudShapes[i % 3][0].count) * 2
            if c.x < 0 && c.fade == 0 { c.x = Double.random(in: 0..<1) * w }
            let want = i < nClouds ? 1.0 : 0.0
            c.fade += max(-0.03, min(0.03, want - c.fade))
            if c.fade > 0 {
                c.x += drift * c.v
                if c.x > w { c.x = -cw; c.fy = 0.05 + 0.3 * Double.random(in: 0..<1) }
                r.clouds.append((c.x.rounded(), (c.fy * h).rounded(), i % 3, 0.65 * c.fade))
            }
            clouds[i] = c
        }
        if kind.fog {
            for i in fog.indices {
                fog[i].x = (fog[i].x + 0.0015).truncatingRemainder(dividingBy: 1.6)
                r.fog.append(((fog[i].x - 0.6) * w, fog[i].fy * h, w * 0.6, 0.14 + 0.05 * sin(Double(tick) / 20 + fog[i].fy * 10)))
            }
        }
        let slant = min(1.2, wind / 25)
        for i in drops.indices {
            if i >= nRain { drops[i].y = -99; continue }
            if drops[i].y < -50 || drops[i].y > h {
                drops[i].x = Double.random(in: 0..<1) * (w + 10) - 10
                drops[i].y = drops[i].y < -50 ? Double.random(in: 0..<1) * h : -4
                drops[i].v = 3.5 + 1.5 * Double.random(in: 0..<1)
            }
            drops[i].y += drops[i].v; drops[i].x += slant
            r.drops.append((drops[i].x, drops[i].y))
        }
        for i in flakes.indices {
            if i >= nSnow { flakes[i].y = -99; continue }
            if flakes[i].y < -50 || flakes[i].y > h {
                flakes[i].x = Double.random(in: 0..<1) * w
                flakes[i].y = flakes[i].y < -50 ? Double.random(in: 0..<1) * h : -2
                flakes[i].v = 0.3 + 0.35 * Double.random(in: 0..<1)
                flakes[i].ph = Double.random(in: 0..<6.28)
            }
            flakes[i].y += flakes[i].v
            r.flakes.append((flakes[i].x + 1.5 * sin(Double(tick) / 9 + flakes[i].ph) + slant * flakes[i].y / 4, flakes[i].y))
        }
        if kind.storm && flash <= 0 && Int.random(in: 0..<140) == 0 { flash = 7 }
        if flash > 0 { r.flash = [0, 0.18, 0.05, 0, 0.25, 0.1, 0.04][flash - 1]; flash -= 1 }
        return r
    }

    public func tooltip(weather: Weather?, place: (lat: Double, lon: Double, city: String?)?) -> String {
        var parts: [String] = []
        if forceCode != nil || forcePhase != nil {
            var what: [String] = []
            if let p = forcePhase { what.append(T("phase.\(p)")) }
            if let c = forceCode { what.append(WeatherKind.of(c).name) }
            parts.append("dev · \(what.joined(separator: ", "))")
        } else if let w = weather, Date().timeIntervalSince(w.at) < 3 * 3600 {
            let temp = Int(w.temp.rounded())
            var line = "\(temp > 0 ? "+" : "")\(temp)°, \(WeatherKind.of(w.code).name)"
            if let c = place?.city, !c.isEmpty { line = "\(c) · \(line)" }
            parts.append(line)
            parts.append(T("sky.wind", Int((w.wind / 3.6).rounded())))
        } else {
            parts.append(T("sky.noData"))
        }
        let st = sunTimes(weather: weather, place: place)
        func hm(_ m: Double) -> String { String(format: "%02d:%02d", Int(m) / 60, Int(m) % 60) }
        parts.append(T("sky.sun", hm(st.sr), hm(st.ss)))
        let moon = Astronomy.moonInfo()
        let names = TA("sky.moonNames")
        parts.append(T("sky.moon", names.indices.contains(moon.name) ? names[moon.name] : "", moon.lit))
        return parts.joined(separator: "\n")
    }
}
