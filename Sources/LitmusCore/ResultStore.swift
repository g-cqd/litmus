internal import AemiDigest
internal import AemiIO
internal import AemiKernel
internal import AemiProtobuf
internal import AemiProtobufCore
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus
internal import Synchronization

/// A verdict found by key, and where it came from.
public struct ReusedResult: Sendable {
    public let result: MutationResult
    /// The run that decided it (`RunProvenance.runID`).
    public let runID: String
}

/// Verdicts by reuse key, on disk: one record per key, written atomically, verified on read,
/// evicted oldest first past a size bound.
///
/// Records are protobuf envelopes: field 1 version, field 2 the journal record of the result, field 3 the key, field 4
/// the run id, field 5 the record's tag: SHA-256 of fields 2 to 4, or HMAC-SHA256 with the key in
/// `LITMUS_STORE_KEY` when it is set (then a record without the right tag is ignored: a store that untrusted jobs can
/// write cannot forge verdicts for trusted ones). A record that fails any check is a miss, noted, never trusted.
///
public final class ResultStore: Sendable {
    static let version: UInt64 = 1
    public let directory: String
    public let readOnly: Bool
    public let limitBytes: Int
    private let secret: [UInt8]?
    private let problems = Mutex<[String]>([])

    /// Opens or creates the store at `directory` (refused inside `forbidden`, the subject root).
    public init(directory: String, readOnly: Bool, limitMiB: Int, forbidden: String, secret: String? = nil) throws {
        let directory = canonicalNew(directory)
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

    func recordPath(_ key: String) -> String {
        "\(directory)/v1/records/\(key.prefix(2))/\(key).rec"
    }

    /// The verified result stored under `key` for `mutation`, or nil.
    public func lookup(_ key: String, mutation: Mutation) -> ReusedResult? {
        let file = recordPath(key)
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        do {
            let bytes = try BoundedFileReader.read(path: file, cap: 4 << 20)
            let (record, storedKey, runID) = try decodeRecord(bytes)
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
        let file = recordPath(key)
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // A cache: atomic, not synced. A crash loses the record, never leaves half of one.
        try AtomicFile.replace(at: file, with: encode(record, key: key, runID: runID), durability: .none)
    }

    func recordFiles() -> [(url: URL, date: Date, size: Int)] {
        let root = URL(fileURLWithPath: directory + "/v1/records")
        let keys: [URLResourceKey] = [
            .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey,
        ]
        guard
            let walk = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var found: [(url: URL, date: Date, size: Int)] = []
        while let url = walk.nextObject() as? URL {
            guard url.pathExtension == "rec",
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            let logical = values.fileSize ?? 0
            let size = max(values.totalFileAllocatedSize ?? logical, logical)
            found.append((url, values.contentModificationDate ?? .distantPast, size))
        }
        return found
    }

    /// Removes the least recently used records until the store holds at most 90 % of its limit.
    @discardableResult
    public func evict() -> Int {
        guard !readOnly else { return 0 }
        let files = recordFiles()
        var total = files.reduce(0) { $0 + $1.size }
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

    func decodeRecord(_ bytes: [UInt8]) throws -> (JournalRecord, String, String) {
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
            let stored = fields.4, HMAC.constantTimeEqual(stored, tag(record, key: key, runID: runID))
        else { throw LitmusFailure(secret == nil ? "bad version or digest" : "bad version or tag (LITMUS_STORE_KEY)") }
        return (try ProtobufDecoder().decode(JournalRecord.self, fromBytes: record), key, runID)
    }
}
