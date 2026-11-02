internal import AemiIO
internal import AemiKernel
internal import AemiProtobuf
internal import AemiProtobufCore
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus
internal import Synchronization

/// What a mutant's verdict depends on, as one digest (ADR 0007, design 0001 §4).
///
/// A verdict is reused only when its key matches, and the key holds everything that can change it under the
/// deterministic-test assumption the flaky probe enforces:
/// - the mutant's anchored identity, its text and replacement;
/// - every input of its package and of the local packages that package depends on (analyzerkit's
///   `packageClosure(containing:)`, ADR-0031 there); the whole snapshot for an Xcode project or a layout it cannot read;
/// - the tool version, execution policy, toolchain, build driver, and every option that changes a verdict.
///
/// `--reuse declaration` (nightly only) replaces the closure by the mutant's declaration and its test targets' files:
/// it reuses across edits elsewhere in the module, at the price of soundness, and says so on every reused verdict.
public struct ReuseContext: Sendable {
    /// How much of the code a key covers.
    public enum Mode: String, Codable, Sendable {
        /// Every input that can change the verdict (default; the only mode a pull-request gate may use).
        case closure
        /// The declaration and the covering test targets only (Stryker-like); not sound, labelled as such.
        case declaration
    }

    let mode: Mode
    let context: String
    private let entries: [SnapshotEntry]
    private let wholeSnapshot: String
    private let closures: [String: String]
    private let testFiles: [String: String]

    /// - Parameters:
    ///   - root: the snapshot root, whose entries are `entries`.
    ///   - closureKnown: false for Xcode projects, whose app target the package layout does not describe.
    init(
        mode: Mode,
        root: String,
        entries: [SnapshotEntry],
        wholeSnapshot: String,
        mutations: [Mutation],
        closureKnown: Bool,
        context: ReuseContextInputs
    ) throws {
        self.mode = mode
        self.entries = entries
        self.wholeSnapshot = wholeSnapshot
        self.context = Digest.sha256(try ArtifactCodec.json(context))
        let layout = ProjectLayout.discover(paths: [root])
        let classification = layout.map(ProjectClassification.load)
        var closures: [String: String] = [:]
        var testFiles: [String: String] = [:]
        var byClosure: [[String]: String] = [:]
        let sorted = entries.sorted { $0.path < $1.path }
        func digest(under directories: [String]) -> String {
            if let known = byClosure[directories] { return known }
            let prefixes = directories.map { $0.isEmpty ? "" : $0 + "/" }
            var lines: [UInt8] = []
            for entry in sorted where prefixes.contains(where: { $0.isEmpty || entry.path.hasPrefix($0) }) {
                lines += Array("\(entry.path)\u{0}\(entry.sha256)\n".utf8)
            }
            let value = Digest.sha256(lines)
            byClosure[directories] = value
            return value
        }
        for path in Set(mutations.map(\.path)) {
            let absolute = root + "/" + path
            var directories: [String]?
            if closureKnown, let closure = classification?.packageClosure(containing: absolute),
                closure.allSatisfy({ $0 == root || $0.hasPrefix(root + "/") })
            {
                directories = closure.map { $0 == root ? "" : String($0.dropFirst(root.count + 1)) }
            }
            closures[path] = directories.map { digest(under: $0) } ?? wholeSnapshot
            if mode == .declaration {
                // Every file in a test directory of the closure (of the snapshot when the closure is unknown): a test
                // added or changed anywhere in the package invalidates; a change to the code it calls does not.
                let scope = directories ?? [""]
                let prefixes = scope.map { $0.isEmpty ? "" : $0 + "/" }
                let tests = Self.testDirectories(
                    sorted.filter { entry in prefixes.contains { $0.isEmpty || entry.path.hasPrefix($0) } }
                )
                testFiles[path] = digest(under: tests)
            }
        }
        self.closures = closures
        self.testFiles = testFiles
    }

    /// The directories named `Tests` or ending in `Tests` among `entries`' paths, outermost first.
    private static func testDirectories(_ entries: [SnapshotEntry]) -> [String] {
        var directories: Set<String> = []
        for entry in entries {
            let parts = entry.path.split(separator: "/")
            if let index = parts.firstIndex(where: { $0 == "Tests" || $0.hasSuffix("Tests") }) {
                directories.insert(parts[...index].joined(separator: "/"))
            }
        }
        return directories.sorted()
    }

    /// The key of `mutation`.
    public func key(_ mutation: Mutation) -> String {
        let code: String
        switch mode {
        case .closure: code = closures[mutation.path] ?? wholeSnapshot
        case .declaration:
            code = (mutation.declarationDigest ?? wholeSnapshot) + "|" + (testFiles[mutation.path] ?? wholeSnapshot)
        }
        let fields = [
            "litmus-reuse/v1", mode.rawValue, context, mutation.id, mutation.path, mutation.operatorID.rawValue,
            mutation.original, mutation.replacement, code,
        ]
        return Digest.sha256(Array(fields.joined(separator: "\u{0}").utf8))
    }
}

/// What the run's options and environment contribute to a key: anything that can change a verdict.
struct ReuseContextInputs: Encodable {
    let toolVersion: String
    let executionPolicy: String
    let toolchain: String
    let driver: BuildDriver
    let harness: String
    let failFast: Bool
    let killConfirmation: String
    let memoryLimitMiB: Int
    let timeoutCap: Int
    let timeoutFactor: Int
    let minimumTimeout: Int
    let baselineRepetitions: Int
    let suiteWidth: Int?
    let selectTestTargets: Bool
    let background: Bool
    let excluded: [String]
}

/// A verdict found by key, and where it came from.
public struct ReusedResult: Sendable {
    public let result: MutationResult
    /// The run that decided it (`RunProvenance.runID`).
    public let runID: String
}

/// Verdicts by reuse key, on disk (ADR 0007, design 0001 §4): one record per key, written atomically, verified on read,
/// evicted oldest first past a size bound.
///
/// Records are protobuf envelopes: field 1 version, field 2 the journal record of the result, field 3 the key, field 4
/// the run id, field 5 the record's tag: SHA-256 of fields 2 to 4, or HMAC-SHA256 with the key in
/// `LITMUS_STORE_KEY` when it is set (then a record without the right tag is ignored: a store that untrusted jobs can
/// write cannot forge verdicts for trusted ones). A record that fails any check is a miss, noted, never trusted.
///
/// Waiting for upstream: a verified, size-bounded content-addressed store in aemi (Litmus task t57) would replace the
/// layout and eviction here.
public final class ResultStore: Sendable {
    static let version: UInt64 = 1
    public let directory: String
    public let readOnly: Bool
    public let limitBytes: Int
    private let secret: [UInt8]?
    private let problems = Mutex<[String]>([])

    /// Opens or creates the store at `directory` (refused inside `forbidden`, the subject root).
    public init(directory: String, readOnly: Bool, limitMiB: Int, forbidden: String, secret: String? = nil) throws {
        let directory = SourcePath.canonical(directory)
        guard directory != forbidden, !directory.hasPrefix(forbidden + "/"), !forbidden.hasPrefix(directory + "/")
        else { throw LitmusFailure("the result store must be outside the subject root") }
        let records = directory + "/v1/records"
        let marker = directory + "/v1/litmus-store.json"
        let fm = FileManager.default
        if !fm.fileExists(atPath: marker) {
            guard !readOnly else { throw LitmusFailure("no result store at \(directory)") }
            if fm.fileExists(atPath: directory),
                let contents = try? fm.contentsOfDirectory(atPath: directory), !contents.isEmpty
            {
                throw LitmusFailure("\(directory) is not empty and not a Litmus result store; refusing to write there")
            }
            try fm.createDirectory(atPath: records, withIntermediateDirectories: true)
            try AtomicFile.replace(
                at: marker,
                with: Array("{\"tool\":\"litmus\",\"version\":1}\n".utf8),
                durability: .barrier
            )
        }
        self.directory = directory
        self.readOnly = readOnly
        self.limitBytes = max(1, limitMiB) << 20
        self.secret = (secret?.isEmpty ?? true) ? nil : Array(secret!.utf8)
    }

    /// Problems met reading records (each a miss).
    public var notes: [String] { problems.withLock { $0 } }

    private func path(_ key: String) -> String {
        "\(directory)/v1/records/\(key.prefix(2))/\(key).rec"
    }

    /// The verified result stored under `key` for `mutation`, or nil.
    public func lookup(_ key: String, mutation: Mutation) -> ReusedResult? {
        let file = path(key)
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        do {
            let bytes = try BoundedFileReader.read(path: file, cap: 4 << 20)
            let (record, storedKey, runID) = try decode(bytes)
            guard storedKey == key, let result = record.result, result.mutation.id == mutation.id,
                result.mutation.path == mutation.path, result.mutation.original == mutation.original,
                result.mutation.replacement == mutation.replacement, result.verdict.isResolved
            else {
                problems.withLock {
                    $0.append("result store: record \(key.prefix(12)) does not match its key; ignored")
                }
                return nil
            }
            if !readOnly {
                // Touched for eviction, oldest first.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file)
            }
            return ReusedResult(result: result, runID: runID)
        } catch {
            problems.withLock { $0.append("result store: record \(key.prefix(12)) unreadable (\(error)); ignored") }
            return nil
        }
    }

    /// Stores a resolved, freshly decided result; ignored when read-only.
    public func put(_ key: String, _ result: MutationResult, runID: String) throws {
        guard !readOnly, result.verdict.isResolved, result.reusedFrom == nil else { return }
        let record = try ProtobufEncoder().encodeToBytes(JournalRecord(result))
        let file = path(key)
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // A cache: atomic, not synced. A crash loses the record, never leaves half of one.
        try AtomicFile.replace(at: file, with: encode(record, key: key, runID: runID), durability: .none)
    }

    /// Removes the least recently used records until the store holds at most 90 % of its limit.
    /// - Returns: the records removed.
    @discardableResult
    public func evict() -> Int {
        guard !readOnly else { return 0 }
        let root = URL(fileURLWithPath: directory + "/v1/records")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard
            let walk = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var files: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        while let url = walk.nextObject() as? URL {
            guard url.pathExtension == "rec", let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            let size = values.totalFileAllocatedSize ?? 0
            total += size
            files.append((url, values.contentModificationDate ?? .distantPast, size))
        }
        guard total > limitBytes else { return 0 }
        var removed = 0
        for file in files.sorted(by: { $0.date < $1.date }) where total > limitBytes * 9 / 10 {
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Records

    private func tag(_ record: [UInt8], key: String, runID: String) -> String {
        var message = record
        message += [0] + Array(key.utf8) + [0] + Array(runID.utf8)
        guard let secret else { return Digest.sha256(message) }
        return HMAC.sha256Hex(key: secret, message: message)
    }

    private func encode(_ record: [UInt8], key: String, runID: String) -> [UInt8] {
        var writer = WireWriter()
        writer.appendTag(1, .varint)
        writer.appendVarint(Self.version)
        writer.appendTag(2, .lengthDelimited)
        writer.appendBytes(record)
        writer.appendTag(3, .lengthDelimited)
        writer.appendString(key)
        writer.appendTag(4, .lengthDelimited)
        writer.appendString(runID)
        writer.appendTag(5, .lengthDelimited)
        writer.appendString(tag(record, key: key, runID: runID))
        return writer.bytes
    }

    private func decode(_ bytes: [UInt8]) throws -> (JournalRecord, String, String) {
        let fields = try WireReader.withReader(over: bytes, limits: WireLimits(maxDepth: 8, maxMessageBytes: 4 << 20)) {
            (reader: inout WireReader) throws(WireError) -> (UInt64?, [UInt8]?, String?, String?, String?) in
            var version: UInt64?, record: [UInt8]?, key: String?, run: String?, tag: String?
            while let field = try reader.nextTag() {
                switch (field.fieldNumber, field.wireType) {
                case (1, .varint): version = try reader.readVarint()
                case (2, .lengthDelimited): record = try reader.readBytes()
                case (3, .lengthDelimited): key = try reader.readString()
                case (4, .lengthDelimited): run = try reader.readString()
                case (5, .lengthDelimited): tag = try reader.readString()
                default: try reader.skipField(field)
                }
            }
            return (version, record, key, run, tag)
        }
        guard fields.0 == Self.version, let record = fields.1, let key = fields.2, let runID = fields.3,
            let stored = fields.4, stored == tag(record, key: key, runID: runID)
        else { throw LitmusFailure(secret == nil ? "bad version or digest" : "bad version or tag (LITMUS_STORE_KEY)") }
        return (try ProtobufDecoder().decode(JournalRecord.self, fromBytes: record), key, runID)
    }
}

/// HMAC-SHA256 (RFC 2104) over aemi's SHA-256.
enum HMAC {
    static func sha256Hex(key: [UInt8], message: [UInt8]) -> String {
        let block = 64
        var key = key.count > block ? ContentDigest.sha256(key) : key
        key += [UInt8](repeating: 0, count: block - key.count)
        let inner = ContentDigest.sha256(key.map { $0 ^ 0x36 } + message)
        let outer = ContentDigest.sha256(key.map { $0 ^ 0x5c } + inner)
        return outer.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}
