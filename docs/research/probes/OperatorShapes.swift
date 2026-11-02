// swift-format-ignore-file
// Probe of generated mutation shapes; see ../2026-11-02-mutation-extent-and-thoroughness.md.
import SwiftUI
import Foundation

// Activation constants, as Litmus generates them (simplified initialiser).
nonisolated private let __sel: Swift.String = Foundation.ProcessInfo.processInfo.environment["LITMUS_ACTIVE_ID"] ?? ""
@usableFromInline nonisolated internal let __m1: Swift.Bool = __sel == "1"
@usableFromInline nonisolated internal let __m2: Swift.Bool = __sel == "2"
@usableFromInline nonisolated internal let __m3: Swift.Bool = __sel == "3"

enum Failure: Error { case bad }
enum Kind { case a, b, c }

@MainActor final class Model {
    var items: [Int] = [3, 1, 2]
    var name: String? = nil
    var total = 0
    private var handle: FileHandle? = nil

    // relational boundary/negation, equality, arithmetic, compound assignment, integer and boolean literals
    func arithmetic(_ a: Int, _ b: Int) -> Bool {
        total += (__m1 ? 0 : 1)                                                 // integer literal
        if __m1 { total -= b } else if __m2 { total *= b } else { total += b }   // compound assignment (statement form)
        let sum = (__m1 ? (a - b) : (a + b))                                    // arithmetic
        let flag = (__m1 ? false : true)                                        // boolean literal
        return (__m1 ? (sum <= b) : __m2 ? (sum >= b) : (sum < b)) && flag && (__m3 ? (a != b) : (a == b))
    }

    // nil-coalescing to default, optional binding to nil, condition to constant, not removal, isEmpty negation
    func optional(_ fallback: String) -> String {
        let display = (__m1 ? (fallback) : (name ?? fallback))
        if let name = (__m2 ? nil : name), (__m3 ? true : !name.isEmpty) { return name }
        guard (__m1 ? (items.isEmpty) : (!items.isEmpty)) else { return display }
        return display
    }

    // collection method swap and removal, range boundary
    func collections() -> Int {
        let first = (__m1 ? items.last : items.first) ?? 0
        let ordered = (__m2 ? items : items.sorted())
        let window = (__m3 ? ordered[0...1] : ordered[0..<1])
        return first + window.count
    }

    // return default (statement prefix), void-call removal, cleanup removal, defer removal, throw removal
    func statements(_ value: Int) throws -> Bool {
        if __m1 { return false }
        defer { if !__m2 { handle?.closeFile() } }
        if !__m3 { items.append(value) }
        if value < 0 { if !__m1 { throw Failure.bad } }
        return value > 0
    }

    // single-expression bodies take the expression form of a return default
    func single(_ a: Bool) -> Bool { (__m1 ? false : (a && true)) }
    var count: Int { (__m1 ? 0 : items.count) }
    func async(_ a: Int) async throws -> String? {
        if __m1 { return nil }
        try await Task.sleep(for: .zero)
        return a > 0 ? "x" : nil
    }

    // loop skip, break/continue swap, switch case skip to default
    func loops(_ kinds: [Kind]) -> Int {
        var count = 0
        for kind in kinds where !__m1 {
            switch kind {
            case .a where !__m2: count += 1
            case .b: if __m3 { break } else { continue }
            default: count += 2
            }
        }
        for value in items where (value > 1) && !__m2 { count += value }
        return count
    }
}

struct Badge: View {
    let on: Bool
    let model: Model
    var body: some View {
        VStack {
            if (__m1 ? true : on) { Text((__m2 ? "" : "on")) }
            Button("Go") { if !__m3 { model.items.removeAll() } }  // statement removal inside an action closure
        }
        .opacity((__m1 ? 0 : 1))
    }
}
