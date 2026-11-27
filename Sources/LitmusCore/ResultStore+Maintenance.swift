internal import AemiIO
internal import AemiProtobufCore
internal import Foundation
internal import SourceCorpus

/// Summary of a `ResultStore` on disk (`litmus store status`).
public struct StoreStatus: Codable, Sendable, Equatable {
    public let directory: String
    public let records: Int
    public let corruptRecords: Int
    public let allocatedBytes: Int
    public let logicalBytes: Int
    public let oldestModified: String?
    public let newestModified: String?
}

extension ResultStore {
    private static let packMagic = "litmus-store-pack/v1"

    private struct StoredEntry {
        let url: URL
        let key: String
        let bytes: [UInt8]
        let modified: Date
        let allocated: Int
    }

    private func scanEntries() -> (valid: [StoredEntry], corrupt: [URL]) {
        var valid: [StoredEntry] = []
        var corrupt: [URL] = []
        for file in recordFiles() {
            let stem = file.url.deletingPathExtension().lastPathComponent
            guard let bytes = try? BoundedFileReader.read(path: file.url.path, cap: 4 << 20),
                let (_, storedKey, _) = try? decodeRecord(bytes),
                storedKey == stem,
                Self.isHex64(storedKey)
            else {
                corrupt.append(file.url)
                continue
            }
            valid.append(
                StoredEntry(
                    url: file.url,
                    key: storedKey,
                    bytes: bytes,
                    modified: file.date,
                    allocated: max(file.size, bytes.count)
                )
            )
        }
        return (valid, corrupt)
    }

    private static func isHex64(_ key: String) -> Bool {
        key.utf8.count == 64
            && key.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Inspects an existing store without modifying any files.
    public static func inspect(directory: String, secret: String? = nil) throws -> StoreStatus {
        let store = try ResultStore(
            directory: directory,
            readOnly: true,
            limitMiB: 2048,
            forbidden: "/nonexistent-litmus-root",
            secret: secret
        )
        let (valid, corrupt) = store.scanEntries()
        let formatter = ISO8601DateFormatter()
        let dates = valid.map(\.modified).filter { $0 != .distantPast }
        return StoreStatus(
            directory: store.directory,
            records: valid.count,
            corruptRecords: corrupt.count,
            allocatedBytes: valid.reduce(0) { $0 + $1.allocated },
            logicalBytes: valid.reduce(0) { $0 + $1.bytes.count },
            oldestModified: dates.min().map { formatter.string(from: $0) },
            newestModified: dates.max().map { formatter.string(from: $0) }
        )
    }

    /// Removes corrupt/unverified records, records older than `maxAgeDays`, and oldest records above `maxSizeMiB`.
    public static func garbageCollect(
        directory: String,
        maxAgeDays: Int? = nil,
        maxSizeMiB: Int? = nil,
        secret: String? = nil
    ) throws -> (removedCorrupt: Int, removedExpired: Int, removedOverLimit: Int, remaining: Int) {
        let store = try ResultStore(
            directory: directory,
            readOnly: false,
            limitMiB: maxSizeMiB ?? 2048,
            forbidden: "/nonexistent-litmus-root",
            secret: secret
        )
        let (valid, corrupt) = store.scanEntries()
        var removedCorrupt = 0
        for bad in corrupt where (try? FileManager.default.removeItem(at: bad)) != nil {
            removedCorrupt += 1
        }
        var kept: [StoredEntry] = []
        var removedExpired = 0
        let cutoff = maxAgeDays.map { Date().addingTimeInterval(-Double(max(0, $0)) * 86_400) }
        for entry in valid {
            if let cutoff, entry.modified < cutoff {
                if (try? FileManager.default.removeItem(at: entry.url)) != nil { removedExpired += 1 }
            } else {
                kept.append(entry)
            }
        }
        var removedOverLimit = 0
        if let maxSizeMiB {
            let cap = max(1, maxSizeMiB) << 20
            var total = kept.reduce(0) { $0 + $1.allocated }
            var survivors: [StoredEntry] = []
            for entry in kept.sorted(by: { $0.modified < $1.modified }) {
                if total > cap, (try? FileManager.default.removeItem(at: entry.url)) != nil {
                    total -= entry.allocated
                    removedOverLimit += 1
                } else {
                    survivors.append(entry)
                }
            }
            kept = survivors
        }
        return (removedCorrupt, removedExpired, removedOverLimit, kept.count)
    }

    /// Packs verified store records into a single integrity-checked archive (`litmus store pack`).
    @discardableResult
    public static func pack(directory: String, outputArchive: String, secret: String? = nil) throws -> Int {
        let store = try ResultStore(
            directory: directory,
            readOnly: true,
            limitMiB: 2048,
            forbidden: "/nonexistent-litmus-root",
            secret: secret
        )
        let (valid, _) = store.scanEntries()
        let ordered = valid.sorted { $0.key < $1.key }
        var body = WireWriter()
        body.appendTag(1, .lengthDelimited)
        body.appendString(packMagic)
        for entry in ordered {
            body.appendTag(2, .lengthDelimited)
            body.appendBytes(entry.bytes)
        }
        let bodyDigest = Digest.sha256(body.bytes)
        var outer = WireWriter()
        outer.appendTag(1, .lengthDelimited)
        outer.appendBytes(body.bytes)
        outer.appendTag(2, .lengthDelimited)
        outer.appendString(bodyDigest)
        let outURL = URL(fileURLWithPath: outputArchive)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFile.replace(at: outURL.path, with: outer.bytes, durability: .barrier)
        return ordered.count
    }

    /// Unpacks verified records from a packed archive into `directory` (`litmus store unpack`).
    public static func unpack(
        archivePath: String,
        into directory: String,
        limitMiB: Int = 2048,
        secret: String? = nil
    ) throws -> (imported: Int, skippedExisting: Int) {
        let archiveBytes = try BoundedFileReader.read(path: archivePath, cap: 512 << 20)
        let outer = try WireReader.withReader(
            over: archiveBytes,
            limits: WireLimits(maxDepth: 8, maxMessageBytes: 512 << 20)
        ) { (reader: inout WireReader) throws(WireError) -> ([UInt8]?, String?) in
            var payload: [UInt8]?, digest: String?
            while let field = try reader.nextTag() {
                switch (field.fieldNumber, field.wireType) {
                case (1, .lengthDelimited): payload = try reader.readBytes()
                case (2, .lengthDelimited): digest = try reader.readString()
                default: try reader.skipField(field)
                }
            }
            return (payload, digest)
        }
        guard let payload = outer.0, let expectedDigest = outer.1,
            HMAC.constantTimeEqual(Digest.sha256(payload), expectedDigest)
        else {
            throw LitmusFailure("store archive integrity check failed: \(archivePath)")
        }
        let inner = try WireReader.withReader(
            over: payload,
            limits: WireLimits(maxDepth: 8, maxMessageBytes: 512 << 20)
        ) { (reader: inout WireReader) throws(WireError) -> (String?, [[UInt8]]) in
            var magic: String?
            var records: [[UInt8]] = []
            while let field = try reader.nextTag() {
                switch (field.fieldNumber, field.wireType) {
                case (1, .lengthDelimited): magic = try reader.readString()
                case (2, .lengthDelimited): records.append(try reader.readBytes())
                default: try reader.skipField(field)
                }
            }
            return (magic, records)
        }
        guard inner.0 == packMagic else {
            throw LitmusFailure("unrecognized store archive header in \(archivePath)")
        }
        let store = try ResultStore(
            directory: directory,
            readOnly: false,
            limitMiB: limitMiB,
            forbidden: "/nonexistent-litmus-root",
            secret: secret
        )
        var imported = 0
        var skippedExisting = 0
        for recBytes in inner.1 {
            let (_, key, _) = try store.decodeRecord(recBytes)
            guard Self.isHex64(key) else {
                throw LitmusFailure("refusing invalid record key in store archive")
            }
            let target = store.recordPath(key)
            if FileManager.default.fileExists(atPath: target) {
                skippedExisting += 1
                continue
            }
            try FileManager.default.createDirectory(
                atPath: (target as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try AtomicFile.replace(at: target, with: recBytes, durability: .none)
            imported += 1
        }
        _ = store.evict()
        return (imported, skippedExisting)
    }
}
