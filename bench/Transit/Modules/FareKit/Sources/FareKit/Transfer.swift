/// A change of vehicle within the transfer window is free.
public struct TransferPolicy: Sendable {
    public var windowMinutes: Int
    public var maximumTransfers: Int

    public init(windowMinutes: Int = 60, maximumTransfers: Int = 2) {
        self.windowMinutes = windowMinutes
        self.maximumTransfers = maximumTransfers
    }

    /// Whether boarding at `minute` continues a journey that started at `start` with `transfers` changes so far.
    public func isFreeTransfer(start: Int, minute: Int, transfers: Int) -> Bool {
        guard minute >= start else { return false }
        return minute - start <= windowMinutes && transfers < maximumTransfers
    }

    /// The peak periods: 7:00 to 9:30 and 16:30 to 19:00, weekdays only.
    public static func isPeak(minuteOfDay: Int, weekday: Bool) -> Bool {
        guard weekday else { return false }
        let morning = minuteOfDay >= 7 * 60 && minuteOfDay < 9 * 60 + 30
        let evening = minuteOfDay >= 16 * 60 + 30 && minuteOfDay < 19 * 60
        return morning || evening
    }
}
