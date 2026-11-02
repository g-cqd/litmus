public func gated(_ a: Bool, _ b: Bool) -> Bool { a && b }
public func label(_ flag: Bool) -> Int { flag ? 1 : 2 }
public func permitted(_ flag: Bool) -> Bool {
    if flag { return true }
    return false
}

/// A mutated default argument of a public function: needs an activation a default argument may reference.
public func clamp(_ value: Int, limit: Int = (false ? 1 : 10)) -> Int { min(value, limit) }

/// A mutated `@inlinable` body: needs an activation an inlinable body may reference.
@inlinable public func sign(_ value: Int) -> Int { value >= 0 ? 1 : -1 }

/// Never called by a test: no coverage.
public func untested(_ flag: Bool) -> Bool { flag ? false : true }

/// Its negated guard reads past the end of the array: a crash.
public func element(_ items: [Int], _ index: Int) -> Int? {
    guard index < items.count else { return nil }
    return items[index]
}

/// Its `||` mutant never terminates: a timeout.
public func drain(_ start: Int) -> Int {
    var value = start
    while value > 0 && value < 100 { value -= 1 }
    return value
}

/// A type with `&&` and no `||`: the replaced operator does not compile, an unviable mutant.
public struct Mask: Equatable, Sendable {
    public let bits: UInt8
    public init(_ bits: UInt8) { self.bits = bits }
    public static func && (lhs: Mask, rhs: Mask) -> Mask { Mask(lhs.bits & rhs.bits) }
}

public func overlap(_ first: Mask, _ second: Mask) -> Mask { first && second }
