// swift-format-ignore-file
// Generated-code shape on purpose: imports and selectors after the code, as Litmus writes them.
import SwiftUI

public struct Gate {
    public init() {}
    public func open(_ a: Bool, _ b: Bool, fast: Bool = (__litmus_ab_01 ? (!(true)) : (true))) -> Bool {
        (__litmus_ab_02 ? (a || b) : (a && b))
    }
    @inlinable public func inl(_ a: Bool) -> Int { (__litmus_ab_03 ? (!(a)) : (a)) ? 1 : 2 }
}

public let globalChoice: Int = (__litmus_ab_04 ? (!(Gate().open(true, false))) : (Gate().open(true, false))) ? 1 : 2

struct Badge: View {
    let on: Bool
    var body: some View {
        if (__litmus_ab_05 ? (!(on)) : (on)) { Text("a") } else { Text("b") }
    }
}

actor Counter {
    var n = 0
    func bump(_ flag: Bool) -> Int { if (__litmus_ab_06 ? (!(flag)) : (flag)) { n += 1 }; return n }
}

nonisolated func free(_ x: Int) async -> Bool {
    await Task.yield()
    return (__litmus_ab_07 ? (x > 0 && x < 9) : (x > 0 || x < 9))
}

enum E: Error { case bad }
func typed(_ ok: Bool) throws(E) -> Bool {
    guard (__litmus_ab_08 ? (!(ok)) : (ok)) else { throw .bad }
    return true
}

import Foundation
nonisolated private let __litmus_ab: Swift.String = Foundation.ProcessInfo.processInfo.environment["LITMUS_ACTIVE_ID"] ?? ""
nonisolated private let __litmus_ab_dir: Swift.String? = Foundation.ProcessInfo.processInfo.environment["LITMUS_COVERAGE_DIR"]
nonisolated private func __litmus_ab_reach(_ id: Swift.String) -> Swift.Bool {
    if let directory = __litmus_ab_dir { _ = Foundation.FileManager.default.createFile(atPath: directory + "/" + id, contents: nil) }
    return __litmus_ab == id
}
@usableFromInline nonisolated internal let __litmus_ab_01: Swift.Bool = __litmus_ab_reach("01")
@usableFromInline nonisolated internal let __litmus_ab_02: Swift.Bool = __litmus_ab_reach("02")
@usableFromInline nonisolated internal let __litmus_ab_03: Swift.Bool = __litmus_ab_reach("03")
@usableFromInline nonisolated internal let __litmus_ab_04: Swift.Bool = __litmus_ab_reach("04")
@usableFromInline nonisolated internal let __litmus_ab_05: Swift.Bool = __litmus_ab_reach("05")
@usableFromInline nonisolated internal let __litmus_ab_06: Swift.Bool = __litmus_ab_reach("06")
@usableFromInline nonisolated internal let __litmus_ab_07: Swift.Bool = __litmus_ab_reach("07")
@usableFromInline nonisolated internal let __litmus_ab_08: Swift.Bool = __litmus_ab_reach("08")
