/// Collects what the functions below do, so a test can see a removed call.
public final class Recorder: @unchecked Sendable {
    public private(set) var items: [String] = []
    public init() {}
    public func record(_ item: String) { items.append(item) }
}

public func total(_ price: Int, _ count: Int) -> Int { price * count }

public func average(_ sum: Int, _ count: Int) -> Int { sum / count }

/// `+ 0` changes nothing: its `-` mutant is equivalent and survives.
public func offset(_ value: Int) -> Int { value + 0 }

/// Tested away from the boundary only: the boundary shift survives, the negation does not.
public func within(_ value: Int, _ limit: Int) -> Bool { value <= limit }

public func isEnabled() -> Bool {
    let enabled = true
    return enabled
}

/// String concatenation is not an arithmetic site.
public let banner = "op" + "erators"

public func ping(_ recorder: Recorder) {
    recorder.record("ping")
    recorder.record("pong")
}

/// Its only statement is a call, and no test looks at the recorder: the removal survives.
public func warm(_ recorder: Recorder) { recorder.record("warm") }

/// Logging is never removed; the record call beside it is.
public func noisy(_ recorder: Recorder) {
    print("noisy")
    recorder.record("noisy")
}

/// No test calls it: no coverage.
public func spare(_ value: Int) -> Int { value * 2 }
