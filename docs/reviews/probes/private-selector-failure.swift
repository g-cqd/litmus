// swift-format-ignore-file
// Generated-code shape on purpose: imports and selectors after the code, as Litmus writes them.
public struct Gate {
    public init() {}
    public func open(fast: Bool = (__litmus_ab == "01" ? (!(true)) : (true))) -> Bool { fast }
    @inlinable public func inl(_ a: Bool) -> Int { (__litmus_ab == "03" ? (!(a)) : (a)) ? 1 : 2 }
}
import Foundation
private let __litmus_ab: Swift.String = Foundation.ProcessInfo.processInfo.environment["LITMUS_ACTIVE_ID"] ?? ""
