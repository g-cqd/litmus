internal import AemiIO
internal import AemiProtobuf
internal import AemiProtobufCore
internal import Foundation
internal import SourceCorpus
internal import Synchronization

/// An append-only record of verdicts, one protobuf frame per decision, synced with an AemiIO ordering barrier.
///
/// A run used to rewrite its whole JSON checkpoint after every mutant, O(*n*²) bytes for *n* mutants. The journal costs
/// O(1) per decision and survives a crash: a frame cut short by the crash is reported, never decoded.
///
/// Frames are AemiProtobuf's varint-delimited frames (`FrameEncoder`, `FrameDecoder`); each holds a message with
/// field 1 = version, field 2 = the record, field 3 = the SHA-256 of field 2. Version 2 records are native protobuf
/// (`JournalRecord`); version 1, the AemiJSON of `MutationResult`, is still read.
public final class ResultJournal: Sendable {
    static let version: UInt64 = 2
    private let file: PosixFile
    private let offset: Mutex<Int>

    /// Creates the journal; refused when anything is at `path`, in the same call that creates it (`O_EXCL`).
    public init(path: String) throws {
        do {
            file = try PosixFile(creatingExclusively: path)
        } catch {
            throw LitmusFailure(
                error.errno == EEXIST ? "journal exists: \(path)" : "cannot create the journal \(path): \(error)"
            )
        }
        offset = Mutex(0)
    }

    /// Appends one decision and orders it on storage before returning.
    public func append(_ result: MutationResult) throws {
        let frame = FrameEncoder.varintDelimited(Self.envelope(try Self.record(result)))
        try offset.withLock { (position: inout Int) throws in
            try file.write(frame, at: position)
            try file.sync(.barrier)
            position += frame.count
        }
    }

    /// The encoded record of `result` (version 2).
    static func record(_ result: MutationResult) throws -> [UInt8] {
        try ProtobufEncoder().encodeToBytes(JournalRecord(result))
    }

    /// The frame's message: version, record, and the record's digest.
    static func envelope(_ record: [UInt8], version: UInt64 = version) -> [UInt8] {
        var message = WireWriter()
        message.appendTag(1, .varint)
        message.appendVarint(version)
        message.appendTag(2, .lengthDelimited)
        message.appendBytes(record)
        message.appendTag(3, .lengthDelimited)
        message.appendString(Digest.sha256(record))
        return message.bytes
    }

    /// The decisions recorded in `path`, and whether a trailing frame was cut short.
    public static func read(path: String) throws -> (results: [MutationResult], truncated: Bool) {
        let bytes = try BoundedFileReader.read(path: path, cap: 1 << 30)
        var decoder = FrameDecoder(format: .varintDelimited, maxFrameBytes: 64 << 20)
        decoder.push(bytes)
        var results: [MutationResult] = []
        var position = 0
        while true {
            let frame: Frame?
            do {
                frame = try decoder.next()
            } catch {
                throw LitmusFailure("corrupt journal frame after byte \(position): \(error)")
            }
            guard let frame else { break }
            results.append(try decode(frame.payload, at: position))
            position = bytes.count - decoder.bufferedCount
        }
        do {
            try decoder.finish()
        } catch FrameError.truncated {
            return (results, true)
        } catch {
            throw LitmusFailure("corrupt journal after byte \(position): \(error)")
        }
        return (results, false)
    }

    /// One frame's decision, its digest checked.
    private static func decode(_ message: [UInt8], at position: Int) throws -> MutationResult {
        let fields = try WireReader.withReader(over: message) {
            (reader: inout WireReader) throws(WireError) -> (UInt64?, [UInt8]?, String?) in
            var version: UInt64?, payload: [UInt8]?, digest: String?
            while let tag = try reader.nextTag() {
                switch (tag.fieldNumber, tag.wireType) {
                case (1, .varint): version = try reader.readVarint()
                case (2, .lengthDelimited): payload = try reader.readBytes()
                case (3, .lengthDelimited): digest = try reader.readString()
                default: try reader.skipField(tag)
                }
            }
            return (version, payload, digest)
        }
        guard let payload = fields.1, fields.2 == Digest.sha256(payload) else {
            throw LitmusFailure("corrupt journal frame at byte \(position)")
        }
        switch fields.0 {
        case 1:
            return try ArtifactCodec.decode(MutationResult.self, bytes: payload)
        case 2:
            let record: JournalRecord
            do {
                record = try ProtobufDecoder().decode(JournalRecord.self, fromBytes: payload)
            } catch {
                throw LitmusFailure("corrupt journal record at byte \(position): \(error)")
            }
            guard let result = record.result else {
                throw LitmusFailure("journal record at byte \(position) names a verdict or operator this version lacks")
            }
            return result
        default:
            throw LitmusFailure(
                "journal frame at byte \(position) has unknown version \(fields.0.map(String.init) ?? "none")"
            )
        }
    }
}
