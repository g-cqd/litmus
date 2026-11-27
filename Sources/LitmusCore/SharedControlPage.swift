internal import Foundation

#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#endif

/// The layout of the shared control page: what a schematised test process maps at `LITMUS_SHARED_MAP_<token>` to learn,
/// between two test runs in one process, which mutant is active (shared-process execution, docs/design).
///
/// 64-bit words: `active` (a mutant identifier as a number), `isActive` (nonzero when `active` holds one), `hits` (the
/// active mutant's switch evaluations), `mode` (bit 0: count every switch's evaluations), `slots` (the batch's switch
/// count), `magic`, two reserved words, then one evaluation counter per slot. Fixed size, so the runtime maps it without
/// asking for the file's length.
public enum SharedControlLayout {
    public static let active = 0
    public static let isActive = 1
    public static let hits = 2
    public static let mode = 3
    public static let slots = 4
    public static let magic = 5
    public static let headerWords = 8
    /// The most switches of one schema batch (`SchemaWriter.batches`' largest limit).
    public static let maximumSlots = 1024
    public static let wordCount = headerWords + maximumSlots
    public static let byteCount = wordCount * 8
    /// "LITMUS" and layout version 1; a page without it is ignored, and the process keeps `LITMUS_ACTIVE_ID`.
    public static let magicValue: UInt64 = 0x4C49_544D_5553_0001
    /// `mode` bit: count every switch's evaluations.
    public static let countEvaluations: UInt64 = 1

    /// The slot of each mutant of a batch: its index among the batch's identifiers, sorted.
    public static func slots(for batch: [Mutation]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: batch.map(\.id).sorted().enumerated().map { ($1, $0) })
    }

    /// `id` (16 hex digits) as the number the runtime compares.
    public static func number(of id: String) -> UInt64? {
        id.count == 16 ? UInt64(id, radix: 16) : nil
    }
}

/// The host's side of a shared control page: created per worker process, written only while that process waits for
/// its next command (the command channel orders the writes before the process reads them).
///
/// SAFETY: `words` is the page's own mapping of ``SharedControlLayout/wordCount`` words, unmapped only in `deinit`;
/// every access goes through the subscript with a layout index below that count.
@safe public final class SharedControlPage: @unchecked Sendable {
    public let path: String
    /// The mutant of each slot, by slot.
    public let slots: [String]
    private let words: UnsafeMutablePointer<UInt64>

    /// Creates (or truncates) the file at `path`, maps it, and writes the header for `slots` (at most
    /// ``SharedControlLayout/maximumSlots``); no mutant is active and nothing is counted.
    public init(path: String, slots: [String]) throws {
        guard slots.count <= SharedControlLayout.maximumSlots else {
            throw LitmusFailure("a shared control page holds at most \(SharedControlLayout.maximumSlots) switches")
        }
        let fd = unsafe open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw LitmusFailure("cannot create the shared control page \(path) (errno \(errno))") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(SharedControlLayout.byteCount)) == 0 else {
            throw LitmusFailure("cannot size the shared control page \(path) (errno \(errno))")
        }
        guard let mapped = unsafe mmap(nil, SharedControlLayout.byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
            unsafe mapped != MAP_FAILED
        else {
            throw LitmusFailure("cannot map the shared control page \(path) (errno \(errno))")
        }
        self.path = path
        self.slots = slots
        unsafe self.words = unsafe mapped.bindMemory(to: UInt64.self, capacity: SharedControlLayout.wordCount)
        unsafe words.update(repeating: 0, count: SharedControlLayout.wordCount)
        self[SharedControlLayout.slots] = UInt64(slots.count)
        // Last: a process that maps the page early sees no magic, not a half-written header.
        self[SharedControlLayout.magic] = SharedControlLayout.magicValue
    }

    deinit { _ = unsafe munmap(UnsafeMutableRawPointer(words), SharedControlLayout.byteCount) }

    private subscript(index: Int) -> UInt64 {
        get { unsafe words[index] }
        set { unsafe words[index] = newValue }
    }

    /// Activates `id` (nil: none) and clears its hit count.
    public func activate(_ id: String?) throws {
        self[SharedControlLayout.isActive] = 0
        self[SharedControlLayout.hits] = 0
        guard let id else {
            self[SharedControlLayout.active] = 0
            return
        }
        guard let number = SharedControlLayout.number(of: id) else { throw LitmusFailure("not a mutant id: \(id)") }
        self[SharedControlLayout.active] = number
        self[SharedControlLayout.isActive] = 1
    }

    /// How many times the active mutant's switch was evaluated since ``activate(_:)``.
    public var activeHits: UInt64 { self[SharedControlLayout.hits] }

    /// Whether every switch counts its evaluations (the process-lifetime classification passes).
    public var countsEvaluations: Bool {
        get { self[SharedControlLayout.mode] & SharedControlLayout.countEvaluations != 0 }
        set {
            let mode = self[SharedControlLayout.mode]
            self[SharedControlLayout.mode] =
                newValue ? mode | SharedControlLayout.countEvaluations : mode & ~SharedControlLayout.countEvaluations
        }
    }

    /// Each mutant's evaluation count, from the counters (only those with a slot).
    public func evaluations() -> [String: UInt64] {
        var counts: [String: UInt64] = [:]
        for (slot, id) in slots.enumerated() { counts[id] = self[SharedControlLayout.headerWords + slot] }
        return counts
    }
}
