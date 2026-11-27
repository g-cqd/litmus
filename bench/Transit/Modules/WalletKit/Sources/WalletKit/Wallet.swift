import Foundation

/// The wallet's limits, fixed when first read: a mutant here is evaluated once per process.
public enum WalletLimits {
    public static let maximumBalance = isBusinessAccount(level: 1) ? 50_000 : 20_000
    public static func isBusinessAccount(level: Int) -> Bool {
        if level >= 3 { return true }
        return false
    }
}

/// A process-wide audit trail: a mutant can leave entries behind for the next test (or the next mutant) to see.
/// Locked, so tests running in parallel never race on it.
public final class AuditTrail: @unchecked Sendable {
    public static let shared = AuditTrail()
    private let lock = NSLock()
    private var entries: [String] = []

    public func record(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
    }

    public func contains(_ entry: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains(entry)
    }
}

public enum WalletError: Error, Equatable {
    case overLimit, insufficientFunds, invalidAmount
}

/// A stored-value card balance, in cents.
public struct Wallet: Sendable {
    public private(set) var balance: Int

    public init(balance: Int = 0) { self.balance = balance }

    public mutating func topUp(_ cents: Int) throws {
        guard cents > 0 else { throw WalletError.invalidAmount }
        guard balance + cents <= WalletLimits.maximumBalance else { throw WalletError.overLimit }
        balance += cents
        AuditTrail.shared.record("top-up \(cents)")
    }

    public mutating func pay(_ cents: Int) throws {
        guard cents > 0 else { throw WalletError.invalidAmount }
        if balance >= cents {
            balance -= cents
            AuditTrail.shared.record("pay \(cents)")
        } else {
            AuditTrail.shared.record("declined \(cents)")
            throw WalletError.insufficientFunds
        }
    }

    /// Automatic reload: below the threshold, top up to the target.
    public func reloadAmount(threshold: Int, target: Int) -> Int {
        guard balance < threshold else { return 0 }
        return target - balance
    }

    /// Loyalty points: one per full euro, doubled past 100 euros a month. Overflows trap on absurd amounts.
    public static func points(monthlySpend cents: Int) -> Int {
        let euros = cents / 100
        if euros > 100 { return euros * 2 }
        return euros
    }

    /// The same check twice, on purpose: an equivalent mutant (`>=` and `>` agree because `max` is never equal).
    public static func clampedPercent(_ value: Int) -> Int {
        let bounded = max(-1, min(value, 101))
        if bounded > 100 { return 100 }
        if bounded < 0 { return 0 }
        return bounded
    }
}

/// Station names, formatted once and cached on a shared instance (a lazy var).
public final class StationDirectory: @unchecked Sendable {
    public static let shared = StationDirectory()
    public lazy var displayNames: [String: String] = Self.format(["cent": "central", "port": "harbour"])

    static func format(_ raw: [String: String]) -> [String: String] {
        raw.mapValues { name in
            guard let first = name.first else { return name }
            return first.uppercased() + name.dropFirst()
        }
    }
}
