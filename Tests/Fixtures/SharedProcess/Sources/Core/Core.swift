public enum Limits {
    // 1. A static let from a mutated expression: evaluated once per process.
    public static let maxRetries = isStrict(3) ? 1 : 3
}
public func isStrict(_ level: Int) -> Bool {
    if level > 5 { return true }
    return false
}

// 2. A lazy var on a shared singleton.
public final class Settings: @unchecked Sendable {
    public static let shared = Settings()
    public lazy var pageSize: Int = computePageSize(10)
}
public func computePageSize(_ base: Int) -> Int {
    if base > 0 { return base * 2 }
    return 1
}

// 3. A mutant that corrupts global state before the test fails.
nonisolated(unsafe) public var ledger: [Int] = []
public func record(_ amount: Int) -> Int {
    if amount >= 0 { ledger.append(amount) } else { ledger.append(-1); ledger.append(-1) }
    return ledger.count
}

// 4. A mutant that traps.
public func headroom(_ x: Int) -> Int {
    if x < 10 { return 10 - x }
    return Int.max + x
}

// Ordinary code: kills and a survivor.
public func grade(_ score: Int) -> String {
    if score >= 90 { return "A" }
    if score >= 50 { return "B" }
    return "C"
}
public func clamp(_ x: Int, to limit: Int) -> Int {
    if x > limit { return limit }
    return x
}
