internal import AemiDigest
internal import Foundation

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

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<a.count { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}
