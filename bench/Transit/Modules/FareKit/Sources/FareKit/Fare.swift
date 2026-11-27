/// Who is travelling: the concession decides the discount.
public enum Rider: String, CaseIterable, Sendable {
    case adult, child, senior, student
}

/// Prices in cents, so arithmetic stays exact.
public struct Fare: Equatable, Sendable {
    public let cents: Int
    public init(cents: Int) { self.cents = cents }
}

/// The network's tariff: a base price per zone crossed, a peak surcharge, and concessions.
public struct Tariff: Sendable {
    public var basePerZone: Int
    public var peakSurchargePercent: Int
    public var dailyCapCents: Int

    public init(basePerZone: Int = 180, peakSurchargePercent: Int = 25, dailyCapCents: Int = 900) {
        self.basePerZone = basePerZone
        self.peakSurchargePercent = peakSurchargePercent
        self.dailyCapCents = dailyCapCents
    }

    /// Children under 6 ride free; everyone else pays per zone, at least one zone.
    public func fare(zones: Int, rider: Rider, age: Int, peak: Bool) -> Fare {
        if rider == .child && age < 6 { return Fare(cents: 0) }
        let crossed = max(1, zones)
        var cents = crossed * basePerZone
        if peak && rider != .senior {
            cents += cents * peakSurchargePercent / 100
        }
        cents -= cents * discountPercent(for: rider) / 100
        return Fare(cents: roundedToFive(cents))
    }

    public func discountPercent(for rider: Rider) -> Int {
        switch rider {
        case .adult: return 0
        case .child: return 50
        case .senior: return 40
        case .student: return 30
        }
    }

    /// Rounds to the nearest five cents, halves up.
    public func roundedToFive(_ cents: Int) -> Int {
        let remainder = cents % 5
        return remainder >= 3 ? cents + (5 - remainder) : cents - remainder
    }

    /// What a rider pays for the day's trips, never more than the daily cap.
    public func dailyTotal(_ fares: [Fare]) -> Fare {
        let sum = fares.reduce(0) { $0 + $1.cents }
        return Fare(cents: min(sum, dailyCapCents))
    }
}
