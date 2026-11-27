internal import AemiDigest

/// Cryptographic content identity for execution validity, distinct from fast diagnostic identities.
public enum Digest {
    /// Lower-case hexadecimal SHA-256 of `bytes`, using aemi's platform-backed `ContentDigest`.
    public static func sha256(_ bytes: [UInt8]) -> String {
        ContentDigest.sha256Hex(bytes)
    }
}
