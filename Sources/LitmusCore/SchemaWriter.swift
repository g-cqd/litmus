internal import Foundation

/// Builds conflict-free expression schemas. Edits are nonoverlapping, preventing exponential nested duplication.
public enum SchemaWriter {
    /// Greedy deterministic batching, bounded by `limit` sites per compiled schema.
    public static func batches(_ mutations: [Mutation], limit: Int = 64) -> [[Mutation]] {
        var result: [[Mutation]] = []
        for mutation in mutations.sorted(by: { ($0.path, $0.start, $0.id) < ($1.path, $1.start, $1.id) }) {
            if let index = result.firstIndex(where: { batch in
                batch.count < max(1, limit)
                    && !batch.contains { other in
                        other.path == mutation.path && other.start < mutation.end && mutation.start < other.end
                    }
            }) {
                result[index].append(mutation)
            } else {
                result.append([mutation])
            }
        }
        return result
    }

    /// Verifies source identity, byte ranges, unique IDs and overlap before performing any edit.
    /// A file-private immutable selector is initialized before its first use, including global initializers.
    /// - Note: Requires Foundation in the target; modules are independent but read the same startup environment.
    public static func render(_ source: String, mutations: [Mutation]) throws -> String {
        guard !mutations.isEmpty else { return source }
        let bytes = Array(source.utf8)
        let fingerprint = Digest.sha256(bytes)
        let sorted = mutations.sorted { $0.start < $1.start }
        guard Set(sorted.map(\.id)).count == sorted.count else { throw LitmusFailure("duplicate mutant IDs") }
        var previousEnd = 0
        for site in sorted {
            guard site.sourceFingerprint == fingerprint,
                site.start >= previousEnd, site.end > site.start, site.end <= bytes.count,
                String(decoding: bytes[site.start..<site.end], as: UTF8.self) == site.original
            else { throw LitmusFailure("stale source or overlapping/invalid range for mutant \(site.id)") }
            previousEnd = site.end
        }
        let symbol = "__litmus_" + fingerprint.prefix(16)
        guard !source.contains(symbol) else { throw LitmusFailure("generated symbol collides with source") }
        var output = bytes
        for site in sorted.reversed() {
            guard site.id.allSatisfy({ $0.isHexDigit }) else { throw LitmusFailure("invalid mutant ID") }
            let replacement = "(\(symbol) == \"\(site.id)\" ? (\(site.replacement)) : (\(site.original)))"
            output.replaceSubrange(site.start..<site.end, with: replacement.utf8)
        }
        // Appending preserves the original first line, shebang and source locations preceding the edit.
        let runtime =
            "\nimport Foundation\nprivate let \(symbol): Swift.String = Foundation.ProcessInfo.processInfo.environment[\"LITMUS_ACTIVE_ID\"] ?? \"\"\n"
        return String(decoding: output, as: UTF8.self) + runtime
    }
}
