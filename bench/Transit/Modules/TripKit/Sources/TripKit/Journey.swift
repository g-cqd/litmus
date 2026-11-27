/// One ride: from a stop to a stop, departing and arriving at minutes of the day.
public struct Leg: Equatable, Sendable {
    public let from: String
    public let to: String
    public let departs: Int
    public let arrives: Int

    public init(from: String, to: String, departs: Int, arrives: Int) {
        self.from = from
        self.to = to
        self.departs = departs
        self.arrives = arrives
    }

    public var minutes: Int { arrives - departs }
}

/// A journey is a chain of legs; a connection needs a minimum change time.
public struct Journey: Sendable {
    public let legs: [Leg]
    public let minimumChange: Int

    public init(legs: [Leg], minimumChange: Int = 3) {
        self.legs = legs
        self.minimumChange = minimumChange
    }

    /// Every leg starts where the previous one ended, with enough time to change.
    public var isFeasible: Bool {
        guard !legs.isEmpty else { return false }
        for index in legs.indices.dropFirst() {
            let previous = legs[index - 1], next = legs[index]
            if previous.to != next.from || next.departs - previous.arrives < minimumChange { return false }
        }
        return true
    }

    public var totalMinutes: Int {
        guard let first = legs.first, let last = legs.last else { return 0 }
        return last.arrives - first.departs
    }

    public var changes: Int { max(0, legs.count - 1) }

    /// Waiting time between legs.
    public var waitingMinutes: Int {
        totalMinutes - legs.reduce(0) { $0 + $1.minutes }
    }
}
