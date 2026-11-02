// A simulator test helper: loads a test bundle and runs Swift Testing through its ABI v0 entry point, writing every
// event record (JSON) as a line of the file given; arguments JSON (filters) passed as given.
import Darwin
import Foundation

let t0 = Date()
func mark(_ s: String) {
    FileHandle.standardError.write("\(String(format: "%.2f", Date().timeIntervalSince(t0))) \(s)\n".data(using: .utf8)!)
}

typealias EntryPoint =
    @convention(thin) @Sendable (
        _ configurationJSON: UnsafeRawBufferPointer?,
        _ recordHandler: @escaping @Sendable (_ recordJSON: UnsafeRawBufferPointer) -> Void
    ) async throws -> Bool

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        "usage: helper <bundle binary> <events.jsonl> [configuration JSON]\n".data(using: .utf8)!
    )
    exit(64)
}
guard dlopen(arguments[1], RTLD_LAZY) != nil else {
    FileHandle.standardError.write("dlopen: \(String(cString: dlerror()))\n".data(using: .utf8)!)
    exit(65)
}
mark("dlopen done")
guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint") else {
    FileHandle.standardError.write("no swt_abiv0_getEntryPoint\n".data(using: .utf8)!)
    exit(66)
}
let getEntryPoint = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafeRawPointer).self)
let entryPoint = unsafeBitCast(getEntryPoint(), to: EntryPoint.self)
FileManager.default.createFile(atPath: arguments[2], contents: nil)
let output = FileHandle(forWritingAtPath: arguments[2])!
let lock = NSLock()
let configuration = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 16, alignment: 1)
let text = Array((arguments.count > 3 ? arguments[3] : "{}").utf8)
configuration.copyBytes(from: text)
mark("entry point")
let passed = try await entryPoint(UnsafeRawBufferPointer(rebasing: configuration[0..<text.count])) { record in
    lock.lock(); defer { lock.unlock() }
    output.write(Data(record))
    output.write(Data([0x0A]))
}
mark("run done")
try output.close()
exit(passed ? 0 : 1)
