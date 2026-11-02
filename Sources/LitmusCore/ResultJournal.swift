internal import AemiIO
internal import AemiProtobufCore
internal import Foundation
internal import SourceCorpus
internal import Synchronization

/// An append-only record of verdicts, one protobuf frame per decision, synced with an AemiIO ordering barrier.
///
/// A run used to rewrite its whole JSON checkpoint after every mutant, O(*n*²) bytes for *n* mutants. The journal costs
/// O(1) per decision and survives a crash: a frame cut short by the crash is reported, never decoded.
///
/// Frame: varint length, then a message with field 1 = version (1), field 2 = the `MutationResult` as AemiJSON,
/// field 3 = the SHA-256 of field 2.
public final class ResultJournal: Sendable {
    private let file: PosixFile
    private let offset: Mutex<Int>

    /// Creates the journal; the file must not exist.
    public init(path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { throw LitmusFailure("journal exists: \(path)") }
        file = try PosixFile(path: path, mode: .readWrite(create: true))
        offset = Mutex(0)
    }

    /// Appends one decision and orders it on storage before returning.
    public func append(_ result: MutationResult) throws {
        let json = try ArtifactCodec.json(result)
        var message = WireWriter()
        message.appendTag(1, .varint)
        message.appendVarint(1)
        message.appendTag(2, .lengthDelimited)
        message.appendBytes(json)
        message.appendTag(3, .lengthDelimited)
        message.appendString(Digest.sha256(json))
        var frame = WireWriter(reservingCapacity: message.bytes.count + 10)
        frame.appendVarint(UInt64(message.bytes.count))
        let bytes = frame.bytes + message.bytes
        try offset.withLock { (position: inout Int) throws in
            // SAFETY: `bytes` is an owned array alive for the synchronous call; the buffer does not escape.
            try bytes.withUnsafeBytes { buffer in try unsafe file.pwrite(buffer, at: position) }
            try file.sync(.barrier)
            position += bytes.count
        }
    }

    /// The decisions recorded in `path`, and whether a trailing frame was cut short.
    public static func read(path: String) throws -> (results: [MutationResult], truncated: Bool) {
        let bytes = try BoundedFileReader.read(path: path, cap: 1 << 30)
        var results: [MutationResult] = []
        var position = 0
        while position < bytes.count {
            var length: UInt64 = 0
            var shift: UInt64 = 0
            var cursor = position
            var complete = false
            while cursor < bytes.count, shift < 64 {
                let byte = bytes[cursor]
                length |= UInt64(byte & 0x7f) << shift
                cursor += 1
                if byte & 0x80 == 0 {
                    complete = true
                    break
                }
                shift += 7
            }
            guard complete, length <= UInt64(bytes.count - cursor) else { return (results, true) }
            let message = Array(bytes[cursor..<(cursor + Int(length))])
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
            guard fields.0 == 1, let payload = fields.1, fields.2 == Digest.sha256(payload) else {
                throw LitmusFailure("corrupt journal frame at byte \(position)")
            }
            results.append(try ArtifactCodec.decode(MutationResult.self, bytes: payload))
            position = cursor + Int(length)
        }
        return (results, false)
    }
}
