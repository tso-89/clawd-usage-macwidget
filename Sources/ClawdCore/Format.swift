import Foundation

public enum Fmt {
    /// "3h 03m", "2d 4h", "12m"; nil when the moment has passed.
    public static func span(to end: Date, now: Date = Date()) -> String? {
        let s = end.timeIntervalSince(now)
        guard s > 0 else { return nil }
        let total = Int(s)
        let days = total / 86400, hours = (total % 86400) / 3600, mins = (total % 3600) / 60
        if s >= 86400 { return T("span.d", days, hours) }
        if s >= 3600 { return T("span.h", total / 3600, mins) }
        return T("span.m", mins)
    }

    /// Reset as a clock time: "03:20" today, "tmrw 01:00" tomorrow, "Sun 01:49" further off.
    public static func resetClock(_ at: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let hm = clock(at)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: at)).day ?? 0
        if days <= 0 { return hm }
        if days == 1 { return T("clock.tmrw", hm) }
        let f = DateFormatter(); f.locale = I18n.locale; f.dateFormat = "EEE"
        return "\(f.string(from: at)) \(hm)"
    }

    public static func clock(_ d: Date, seconds: Bool = false) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: d)
    }

    public static func gb(_ v: Double) -> String {
        v >= 10 ? String(format: "%.0f GB", v) : String(format: "%.1f GB", v)
    }
}

/// Colours shared by the app; hex "#RRGGBB" or "#AARRGGBB".
public enum Palette {
    public static let ok = "#4ADE80", warn = "#FBBF24", crit = "#F87171", dead = "#6B7280"
    public static func level(_ l: Level) -> String {
        switch l { case .ok: return ok; case .warn: return warn; case .crit: return crit; case .dead: return dead }
    }
}
