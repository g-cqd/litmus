public func gated(_ a: Bool, _ b: Bool) -> Bool { a && b }
public func label(_ flag: Bool) -> Int { flag ? 1 : 2 }
public func permitted(_ flag: Bool) -> Bool {
    if flag { return true }
    return false
}
