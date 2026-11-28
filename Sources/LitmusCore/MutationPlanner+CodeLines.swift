internal import Foundation
internal import SourceCorpus
internal import SwiftParser
internal import SwiftSyntax

extension MutationPlanner {
    /// The 1-based lines of the Swift file at `path` that hold part of a token (code, not only comments or blank
    /// space); nil when the file cannot be read.
    static func codeLines(of path: String) -> Set<Int>? {
        guard let bytes = try? BoundedFileReader.read(path: path, cap: 8 << 20) else { return nil }
        let tree = Parser.parse(source: String(decoding: bytes, as: UTF8.self))
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        var lines: Set<Int> = []
        for token in tree.tokens(viewMode: .sourceAccurate) where token.tokenKind != .endOfFile {
            let first = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            let last = converter.location(for: token.endPositionBeforeTrailingTrivia).line
            lines.formUnion(first...max(first, last))
        }
        return lines
    }
}
