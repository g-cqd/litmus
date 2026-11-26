internal import AemiIO
internal import AemiJSON
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus

/// The current schema files of a batch, by absolute snapshot path.
struct InstalledSchema {
    let originals: [String: Data]
    let rendered: [String: RenderedSchema]
    /// In place: restores go through the journal, which puts an original back only over the schema it recorded.
    var journal: InPlaceJournal? = nil

    func restore() throws {
        if let journal {
            try journal.restoreAll()
            return
        }
        for (path, data) in originals { try AtomicFile.replace(at: path, with: [UInt8](data), durability: .none) }
    }
}

/// Compiler errors of a failed build, `path:line:column: error: message`, as swiftc and xcodebuild print them.
struct CompilerDiagnostics {
    struct Error {
        let path: String
        let line: Int
        let column: Int?
        let message: String
    }
    let errors: [Error]

    init(_ build: ProcessOutput, snapshotRoot: String) {
        var errors: [Error] = []
        let text = Self.plain(build.stdout + Array("\n".utf8) + build.stderr)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: ": error: ") else { continue }
            let location = line[..<marker.lowerBound].split(separator: ":")
            guard location.count >= 3, let number = Int(location[location.count - 2]) else { continue }
            let column = Int(location[location.count - 1])
            let path = SourcePath.canonical(location.dropLast(2).joined(separator: ":"))
            guard path.hasPrefix(snapshotRoot + "/") else { continue }
            errors.append(Error(path: path, line: number, column: column, message: String(line[marker.upperBound...])))
        }
        self.errors = errors
    }

    /// The first line saying `error:` of any kind (`xcodebuild: error: Unable to find a device…`), at most 300
    /// characters: what a failed build says when no compiler diagnostic names a file.
    static func firstError(_ build: ProcessOutput) -> String? {
        let text = plain(build.stdout + Array("\n".utf8) + build.stderr)
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("error:") }) else {
            return nil
        }
        return String(line.trimmingCharacters(in: .whitespaces).prefix(300))
    }

    /// `bytes` without terminal escape sequences: compilers colour their diagnostics (CSI `ESC [ … letter`) and link
    /// documentation (OSC `ESC ] … BEL` or `ESC ] … ESC \\`) even when the output is a pipe.
    static func plain(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B, index + 1 < bytes.count else {
                output.append(bytes[index])
                index += 1
                continue
            }
            index += 1
            if bytes[index] == UInt8(ascii: "[") {
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) { index += 1 }
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                while index < bytes.count, bytes[index] != 0x07,
                    !(bytes[index] == 0x1B && index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "\\"))
                {
                    index += 1
                }
                index += bytes.indices.contains(index) && bytes[index] == 0x1B ? 2 : 1
            } else {
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// The mutants whose replacement covers an error's `(line, column)` byte offset (pinpointing the narrowest nested
    /// replacement branch when `column` is present), falling back to line-range matching otherwise.
    func suspects(in rendered: [String: RenderedSchema]) -> [String] {
        var ids: Set<String> = []
        var lineStartsCache: [String: [Int]] = [:]
        func byteOffset(in path: String, text: String, line: Int, column: Int) -> Int? {
            let starts: [Int]
            if let cached = lineStartsCache[path] {
                starts = cached
            } else {
                var built = [0]
                let utf8 = Array(text.utf8)
                for idx in utf8.indices where utf8[idx] == 0x0A { built.append(idx + 1) }
                lineStartsCache[path] = built
                starts = built
            }
            guard line >= 1, line <= starts.count, column >= 1 else { return nil }
            return starts[line - 1] + (column - 1)
        }
        for error in errors {
            guard let schema = rendered[error.path] else { continue }
            if let column = error.column,
                let offset = byteOffset(in: error.path, text: schema.text, line: error.line, column: column),
                let exact = schema.branchBytes
                    .filter({ $0.value.contains(offset) })
                    .min(by: { ($0.value.count, $0.key) < ($1.value.count, $1.key) })
            {
                ids.insert(exact.key)
                continue
            }
            for (id, lines) in schema.lines where lines.contains(error.line) { ids.insert(id) }
        }
        return ids.sorted()
    }
}
