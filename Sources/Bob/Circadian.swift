import SwiftUI

/// bob's shared sense of the hour. Every bit of color in the app — the comet
/// border, the ambient wash, bob's spoken voice — reads from here, so the whole
/// app lives in the same light. Continuous, not a hard 8pm flip: the warmth
/// glides from cool morning through golden evening into deep ember past
/// midnight. Anchors tuned for a founder who's often up late (IST).
enum Circadian {
    /// Fractional hour 0..<24 in the user's local time, e.g. 18.5 = 6:30pm.
    static func hour(_ date: Date = Date()) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let h = Double(c.hour ?? 0)
        let m = Double(c.minute ?? 0)
        let s = Double(c.second ?? 0)
        return h + m / 60 + s / 3600
    }

    /// The late-night register — drives "still up, p.", the coral comet, the
    /// low slow voice. Kept as a hard boundary because the *greeting words* and
    /// voice register read more naturally as a threshold than a gradient.
    static func isNight(_ date: Date = Date()) -> Bool {
        let h = hour(date)
        return h >= 20 || h < 6
    }

    // MARK: keyframed palettes

    private struct RGB {
        var r, g, b: Double
        var color: Color { Color(red: r, green: g, blue: b) }
        static func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
            RGB(r: a.r + (b.r - a.r) * t,
                g: a.g + (b.g - a.g) * t,
                b: a.b + (b.b - a.b) * t)
        }
    }

    /// Interpolate a keyframe table keyed by hour (must be sorted, wraps at 24).
    private static func sample(_ keys: [(Double, RGB)], at h: Double) -> RGB {
        guard let first = keys.first else { return RGB(r: 0.5, g: 0.5, b: 0.5) }
        if h <= first.0 {
            // wrap: blend last (as if at hour-24) → first
            let last = keys[keys.count - 1]
            let span = (24 - last.0) + first.0
            let t = span == 0 ? 0 : ((h + 24 - last.0).truncatingRemainder(dividingBy: 24)) / span
            return RGB.lerp(last.1, first.1, t)
        }
        for i in 0..<(keys.count - 1) {
            let (h0, c0) = keys[i]
            let (h1, c1) = keys[i + 1]
            if h >= h0 && h <= h1 {
                let t = (h - h0) / (h1 - h0)
                return RGB.lerp(c0, c1, t)
            }
        }
        // past the last key → wrap toward first
        let last = keys[keys.count - 1]
        let span = (24 - last.0) + first.0
        let t = span == 0 ? 0 : (h - last.0) / span
        return RGB.lerp(last.1, first.1, t)
    }

    /// The bright comet accent color, continuous across the day.
    /// blue daylight → amber golden-hour → coral ember night → cool pre-dawn.
    private static let accentKeys: [(Double, RGB)] = [
        (1,  RGB(r: 1.00, g: 0.30, b: 0.40)),  // dead of night — coral ember
        (6,  RGB(r: 0.62, g: 0.60, b: 0.95)),  // dawn — periwinkle
        (10, RGB(r: 0.45, g: 0.78, b: 1.00)),  // morning — bob's blue
        (15, RGB(r: 0.40, g: 0.80, b: 0.98)),  // afternoon — cool blue
        (18, RGB(r: 1.00, g: 0.66, b: 0.32)),  // golden hour — amber
        (21, RGB(r: 1.00, g: 0.40, b: 0.42)),  // evening — warm coral
    ]

    // Memoize per minute-of-day — the color is effectively constant over many
    // seconds, but accent() is called every frame inside the comet's Canvas.
    // Accessed from the main thread (Canvas/SwiftUI) only.
    nonisolated(unsafe) private static var accentCache: (key: Int, color: Color)?

    static func accent(_ date: Date = Date()) -> Color {
        let h = hour(date)
        let key = Int(h * 60)
        if let c = accentCache, c.key == key { return c.color }
        let color = sample(accentKeys, at: h).color
        accentCache = (key, color)
        return color
    }

    /// A trio of soft background-wash colors for the idle "hour wash" — the
    /// whole window living in the room's light when nothing's playing.
    private static let washKeys: [(Double, [RGB])] = [
        (1,  [RGB(r: 0.20, g: 0.10, b: 0.32), RGB(r: 0.32, g: 0.12, b: 0.20), RGB(r: 0.10, g: 0.10, b: 0.28)]), // ember/indigo night
        (4,  [RGB(r: 0.10, g: 0.12, b: 0.26), RGB(r: 0.16, g: 0.14, b: 0.30), RGB(r: 0.08, g: 0.10, b: 0.20)]), // deepest
        (7,  [RGB(r: 0.40, g: 0.34, b: 0.46), RGB(r: 0.58, g: 0.40, b: 0.42), RGB(r: 0.30, g: 0.34, b: 0.50)]), // dawn rose/slate
        (10, [RGB(r: 0.62, g: 0.54, b: 0.36), RGB(r: 0.50, g: 0.56, b: 0.62), RGB(r: 0.66, g: 0.60, b: 0.44)]), // soft morning gold
        (14, [RGB(r: 0.44, g: 0.52, b: 0.64), RGB(r: 0.56, g: 0.58, b: 0.62), RGB(r: 0.48, g: 0.56, b: 0.66)]), // cool midday
        (18, [RGB(r: 0.74, g: 0.46, b: 0.34), RGB(r: 0.70, g: 0.38, b: 0.44), RGB(r: 0.46, g: 0.34, b: 0.52)]), // golden hour amber-rose
        (21, [RGB(r: 0.34, g: 0.20, b: 0.44), RGB(r: 0.48, g: 0.22, b: 0.32), RGB(r: 0.18, g: 0.16, b: 0.38)]), // evening indigo ember
    ]

    nonisolated(unsafe) private static var washCache: (key: Int, colors: [Color])?

    static func wash(_ date: Date = Date()) -> [Color] {
        let h = hour(date)
        let key = Int(h * 6) // every 10 minutes is plenty for a background wash
        if let c = washCache, c.key == key { return c.colors }
        var out: [Color] = []
        for slot in 0..<3 {
            let keys = washKeys.map { ($0.0, $0.1[slot]) }
            out.append(sample(keys, at: h).color)
        }
        washCache = (key, out)
        return out
    }
}
