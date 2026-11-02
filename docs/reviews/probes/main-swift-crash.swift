// swift-format-ignore-file
// Generated-code shape on purpose: imports and selectors after the code, as Litmus writes them.
let flag = CommandLine.arguments.count > 5
print((__litmus_ab == "01" ? (!(flag)) : (flag)) ? "a" : "b")
import Foundation
private let __litmus_ab: Swift.String = Foundation.ProcessInfo.processInfo.environment["LITMUS_ACTIVE_ID"] ?? ""
