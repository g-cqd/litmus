internal import Foundation
internal import AemiJSON
internal import AemiProtobufCore
internal import SourceCorpus

/// Versioned protobuf envelope: field 1 version, field 2 JSON payload, field 3 SHA-256 integrity digest.
/// This initial wire format deliberately retains one canonical model across JSON and binary artifacts.
public enum ArtifactWire {
    public static let byteCap = 32 << 20

    public static func encode(_ json: [UInt8]) -> [UInt8] {
        var writer = WireWriter()
        writer.appendTag(1, .varint); writer.appendVarint(1)
        writer.appendTag(2, .lengthDelimited); writer.appendBytes(json)
        writer.appendTag(3, .lengthDelimited); writer.appendString(Digest.sha256(json))
        return writer.bytes
    }

    /// Rejects unknown versions, duplicate required fields, corruption and oversized/truncated messages.
    public static func decode(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count <= byteCap else { throw LitmusFailure("artifact exceeds 32 MiB") }
        let fields = try WireReader.withReader(over: bytes, limits: WireLimits(maxDepth: 8, maxMessageBytes: byteCap)) { (reader: inout WireReader) throws(WireError) -> (UInt64?, [UInt8]?, String?, Bool) in
            var version: UInt64?, payload: [UInt8]?, digest: String?, duplicate = false
            while let tag = try reader.nextTag() {
                switch (tag.fieldNumber, tag.wireType) {
                case (1, .varint): duplicate = duplicate || version != nil; version = try reader.readVarint()
                case (2, .lengthDelimited): duplicate = duplicate || payload != nil; payload = try reader.readBytes()
                case (3, .lengthDelimited): duplicate = duplicate || digest != nil; digest = try reader.readString()
                default: try reader.skipField(tag)
                }
            }
            return (version, payload, digest, duplicate)
        }
        guard fields.0 == 1, let payload = fields.1, let digest = fields.2, !fields.3,
            Digest.sha256(payload) == digest else { throw LitmusFailure("unsupported, duplicate or corrupt artifact envelope") }
        return payload
    }
}

/// All external model encoding uses AemiJSON; reads are bounded before decoding, writes atomic.
public enum ArtifactCodec {
    public static func json<T: Encodable>(_ value: T) throws -> [UInt8] {
        var encoder = AemiJSON.JSONEncoder()
        encoder.options.keyOrder = .sorted
        encoder.prettyPrinted = true
        let bytes = try encoder.encodeToBytes(value)
        guard bytes.count <= ArtifactWire.byteCap - 1024 else { throw LitmusFailure("encoded artifact exceeds limit") }
        return bytes
    }
    public static func decode<T: Decodable>(_ type: T.Type, bytes: [UInt8]) throws -> T {
        var decoder = AemiJSON.JSONDecoder()
        decoder.options = .iJSON
        return try decoder.decode(type, from: Data(bytes))
    }
    /// Bounded CLI report-scope input, one UTF-8 path per line; no unbounded Foundation convenience read.
    public static func paths(from path: String) throws -> [String] {
        let bytes = try BoundedFileReader.read(path: path, cap: 1 << 20)
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw LitmusFailure("scope is not UTF-8") }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }
    public static func read<T: Decodable>(_ type: T.Type, path: String) throws -> T {
        let bytes = try BoundedFileReader.read(path: path, cap: ArtifactWire.byteCap)
        return try decode(type, bytes: path.hasSuffix(".pb") ? ArtifactWire.decode(bytes) : bytes)
    }
    public static func write<T: Encodable>(_ value: T, path: String) throws {
        let bytes = try json(value)
        let output = path.hasSuffix(".pb") ? ArtifactWire.encode(bytes) : bytes
        try Data(output).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
