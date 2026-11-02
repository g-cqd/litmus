// swift-format-ignore-file
// Probe of generated mutation shapes; see ../2026-11-02-mutation-extent-and-thoroughness.md.
import Foundation
@usableFromInline nonisolated internal let __m1: Swift.Bool = Foundation.ProcessInfo.processInfo.environment["X"] == "1"
enum Kind { case a, b }
final class Owner { var value = 1; func run(_ body: @escaping () -> Void) { body() } }
func shapes(_ kind: Kind, _ name: String, _ owner: Owner) -> String {
    let joined = (__m1 ? (name - "!") : (name + "!"))                      // arithmetic on a String
    switch kind { case .a where !__m1: return joined; case .b: return name } // case skip without a default
}
extension Owner {
    func capture() { run { [self] in guard let self else { return }; self.value += 1 } } // weak → strong with guard let self
}
func implicit(_ a: Bool) -> Bool {
    if __m1 { return false }
    a                                                                      // a statement before an implicit return
}
