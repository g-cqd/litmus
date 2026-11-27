/// How a delay on one leg propagates through the rest of a journey.
public enum DelayPropagation {
    /// The legs still reachable after the leg at `index` arrives `delay` minutes late; slack absorbs part of it.
    public static func reachableLegs(in journey: Journey, delayedLeg index: Int, by delay: Int) -> Int {
        guard journey.legs.indices.contains(index) else { return 0 }
        var lateness = delay
        var reachable = index + 1
        var next = index + 1
        while next < journey.legs.count {
            let slack = journey.legs[next].departs - journey.legs[next - 1].arrives - journey.minimumChange
            if lateness > slack { break }
            lateness = max(0, lateness - slack)
            reachable += 1
            next += 1
        }
        return reachable
    }

    /// Stops a late vehicle needs to recover `delay` minutes, catching up `perStop` at each (bounded by sanity).
    public static func stopsToRecover(delay: Int, perStop: Int) -> Int {
        guard perStop > 0 else { return Int.max }
        var remaining = delay
        var stops = 0
        while remaining > 0 && remaining < 10_000 {
            remaining -= perStop
            stops += 1
        }
        return stops
    }

    /// A delay of `minutes` is reported as on time, minor (under 5) or major.
    public static func label(for minutes: Int) -> String {
        if minutes <= 0 { return "on time" }
        return minutes < 5 ? "minor delay" : "major delay"
    }
}
