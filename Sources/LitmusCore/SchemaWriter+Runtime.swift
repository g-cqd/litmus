internal import Foundation

extension SchemaWriter {
    /// Emits the per-file runtime without adding `import Foundation`, using `@_silgen_name` C bindings for environment
    /// and marker/trace file I/O so files in modules with `internal import Foundation` or `private import Foundation`
    /// never suffer access-level import collisions.
    static func runtime(symbol: String, switches: [(id: String, slot: Int)], token: String) -> String {
        func key(_ base: String) -> String { ActivationEnvironment.key(base, token: token) }
        let byteCount = SharedControlLayout.byteCount
        let magicIndex = SharedControlLayout.magic, magicValue = SharedControlLayout.magicValue
        let modeIndex = SharedControlLayout.mode, slotsIndex = SharedControlLayout.slots
        let headerWords = SharedControlLayout.headerWords, hitsIndex = SharedControlLayout.hits
        let isActiveIndex = SharedControlLayout.isActive, activeIndex = SharedControlLayout.active
        func helperBlock(strict: Bool) -> String {
            let atUnsafe = strict ? "@unsafe " : ""
            let kwUnsafe = strict ? "unsafe " : ""
            // SAFETY (the page): `words` is a mapping of the whole fixed layout, never unmapped, indexed only below it.
            let atSafe = strict ? "@safe " : ""
            return """
                \(atUnsafe)@_silgen_name("getenv") nonisolated private func \(symbol)_getenv(_ name: Swift.UnsafePointer<Swift.CChar>) -> Swift.UnsafeMutablePointer<Swift.CChar>?
                \(atUnsafe)@_silgen_name("open") nonisolated private func \(symbol)_open(_ path: Swift.UnsafePointer<Swift.CChar>, _ oflag: Swift.Int32, _ mode: Swift.UInt32) -> Swift.Int32
                @_silgen_name("close") nonisolated private func \(symbol)_close(_ fd: Swift.Int32) -> Swift.Int32
                \(atUnsafe)@_silgen_name("write") nonisolated private func \(symbol)_write(_ fd: Swift.Int32, _ buf: Swift.UnsafeRawPointer, _ nbyte: Swift.Int) -> Swift.Int
                \(atUnsafe)@_silgen_name("os_unfair_lock_lock") nonisolated private func \(symbol)_lock(_ lock: Swift.UnsafeMutablePointer<Swift.UInt32>)
                \(atUnsafe)@_silgen_name("os_unfair_lock_unlock") nonisolated private func \(symbol)_unlock(_ lock: Swift.UnsafeMutablePointer<Swift.UInt32>)
                \(atUnsafe)@_silgen_name("mmap") nonisolated private func \(symbol)_mmap(_ address: Swift.UnsafeMutableRawPointer?, _ length: Swift.Int, _ protection: Swift.Int32, _ flags: Swift.Int32, _ fd: Swift.Int32, _ offset: Swift.Int64) -> Swift.UnsafeMutableRawPointer?
                nonisolated private func \(symbol)_env(_ key: Swift.StaticString) -> Swift.String? {
                    key.withUTF8Buffer { buffer in
                        \(kwUnsafe)buffer.baseAddress.flatMap { base in
                            \(kwUnsafe)\(symbol)_getenv(Swift.UnsafeRawPointer(base).assumingMemoryBound(to: Swift.CChar.self))
                                .map { \(kwUnsafe)Swift.String(cString: $0) }
                        }
                    }
                }
                /// The shared control page (`SharedControlLayout`), when the run maps one; nil keeps `LITMUS_ACTIVE_ID`.
                \(atSafe)nonisolated private final class \(symbol)_Page: @unchecked Swift.Sendable {
                    private let words: Swift.UnsafeMutablePointer<Swift.UInt64>
                    private var rawLock: Swift.UInt32 = 0
                    private init(_ words: Swift.UnsafeMutablePointer<Swift.UInt64>) { \(kwUnsafe)self.words = words }
                    static func map() -> \(symbol)_Page? {
                        guard let path = \(symbol)_env("\(key(ActivationEnvironment.sharedControlPage))"), !path.isEmpty else { return nil }
                        var bytes = Swift.Array(path.utf8)
                        bytes.append(0)
                        let fd: Swift.Int32 = bytes.withUnsafeBufferPointer { buffer in
                            guard let base = buffer.baseAddress else { return -1 }
                            return \(kwUnsafe)\(symbol)_open(Swift.UnsafeRawPointer(base).assumingMemoryBound(to: Swift.CChar.self), 0x0002, 0)
                        }
                        guard fd >= 0 else { return nil }
                        defer { _ = \(symbol)_close(fd) }
                        guard let raw = \(kwUnsafe)\(symbol)_mmap(nil, \(byteCount), 3, 1, fd, 0), Swift.Int(bitPattern: raw) != -1 else { return nil }
                        let words = \(kwUnsafe)raw.assumingMemoryBound(to: Swift.UInt64.self)
                        guard \(kwUnsafe)words[\(magicIndex)] == \(magicValue) else { return nil }
                        return \(kwUnsafe)\(symbol)_Page(words)
                    }
                    /// Adds one to word `index` under this file's lock (a slot, or the hits only the active switch writes).
                    private func bump(_ index: Swift.Int) {
                        Swift.withUnsafeMutablePointer(to: &rawLock) { ptr in \(kwUnsafe)\(symbol)_lock(ptr) }
                        \(kwUnsafe)words[index] &+= 1
                        Swift.withUnsafeMutablePointer(to: &rawLock) { ptr in \(kwUnsafe)\(symbol)_unlock(ptr) }
                    }
                    /// Whether `id` is active; counts the evaluation in `slot` while the page asks for counts.
                    func check(_ id: Swift.UInt64, _ slot: Swift.Int) -> Swift.Bool {
                        if \(kwUnsafe)words[\(modeIndex)] & 1 != 0, slot < Swift.Int(truncatingIfNeeded: \(kwUnsafe)words[\(slotsIndex)]) {
                            bump(\(headerWords) + slot)
                        }
                        guard \(kwUnsafe)words[\(isActiveIndex)] != 0, \(kwUnsafe)words[\(activeIndex)] == id else { return false }
                        bump(\(hitsIndex))
                        return true
                    }
                }
                nonisolated private final class \(symbol)_Tracker: @unchecked Swift.Sendable {
                    private var rawLock: Swift.UInt32 = 0
                    private var touched = Swift.Set<Swift.String>()
                    private var traceFD: Swift.Int32 = -1
                    init() {
                        if let path = \(symbol)_trace, !path.isEmpty {
                            var bytes = Swift.Array(path.utf8)
                            bytes.append(0)
                            traceFD = bytes.withUnsafeBufferPointer { buffer in
                                guard let base = buffer.baseAddress else { return -1 }
                                return \(kwUnsafe)\(symbol)_open(
                                    Swift.UnsafeRawPointer(base).assumingMemoryBound(to: Swift.CChar.self),
                                    0x0009,
                                    0o644
                                )
                            }
                        }
                    }
                    func record(_ id: Swift.String, directory: Swift.String?) {
                        Swift.withUnsafeMutablePointer(to: &rawLock) { ptr in \(kwUnsafe)\(symbol)_lock(ptr) }
                        defer { Swift.withUnsafeMutablePointer(to: &rawLock) { ptr in \(kwUnsafe)\(symbol)_unlock(ptr) } }
                        if let directory, touched.insert(id).inserted {
                            var bytes = Swift.Array((directory + "/" + id).utf8)
                            bytes.append(0)
                            bytes.withUnsafeBufferPointer { buffer in
                                guard let base = buffer.baseAddress else { return }
                                let fd = \(kwUnsafe)\(symbol)_open(
                                    Swift.UnsafeRawPointer(base).assumingMemoryBound(to: Swift.CChar.self),
                                    0x0201,
                                    0o644
                                )
                                if fd >= 0 { _ = \(symbol)_close(fd) }
                            }
                        }
                        if traceFD >= 0 {
                            let line = Swift.Array(("{\\"litmusReach\\":\\"" + id + "\\"}\\n").utf8)
                            line.withUnsafeBytes { raw in
                                if let ptr = raw.baseAddress { _ = \(kwUnsafe)\(symbol)_write(traceFD, ptr, raw.count) }
                            }
                        }
                    }
                }
                """
        }
        var text = """
            // litmus: generated mutation schema; this copy is never written back to the source tree
            #if hasFeature(StrictMemorySafety)
            \(helperBlock(strict: true))
            #else
            \(helperBlock(strict: false))
            #endif
            nonisolated private let \(symbol): Swift.String = \(symbol)_env("\(key(ActivationEnvironment.activeID))") ?? ""
            nonisolated private let \(symbol)_dir: Swift.String? = \(symbol)_env("\(key(ActivationEnvironment.coverageDirectory))")
            nonisolated private let \(symbol)_trace: Swift.String? = \(symbol)_env("\(key(ActivationEnvironment.testTracePath))")
            nonisolated private let \(symbol)_tracker = \(symbol)_Tracker()
            nonisolated private let \(symbol)_tracks: Swift.Bool = \(symbol)_dir != nil || \(symbol)_trace != nil
            nonisolated private let \(symbol)_page: \(symbol)_Page? = \(symbol)_Page.map()
            @inline(__always) nonisolated private func \(symbol)_reach(_ id: Swift.String) -> Swift.Bool {
                \(symbol)_tracker.record(id, directory: \(symbol)_dir)
                return true
            }

            """
        for (id, slot) in switches {
            text += """
                nonisolated private let \(symbol)_on_\(id): Swift.Bool = \(symbol) == "\(id)"
                @usableFromInline nonisolated internal var \(symbol)_\(id): Swift.Bool {
                    if \(symbol)_tracks { _ = \(symbol)_reach("\(id)") }
                    if let page = \(symbol)_page { return page.check(0x\(id), \(slot)) }
                    return \(symbol)_on_\(id)
                }

                """
        }
        return text
    }
}
