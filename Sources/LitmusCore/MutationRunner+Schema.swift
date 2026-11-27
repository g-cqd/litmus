internal import AemiIO
internal import AemiJSON
internal import AemiRuntime
internal import Foundation
internal import ProjectModel
internal import SourceCorpus

extension MutationRunner {
    /// For each mutant, the test modules that can reach its file: the test targets analyzerkit finds from the
    /// manifests (`ProjectClassification.testTargets(covering:)`), as module names, among `modules`
    /// (those the suite has). A mutant whose file no target claims, or whose targets are not among them, is left out:
    /// it runs every module.
    static func coveringModules(_ mutations: [Mutation], root: String, modules: Set<String>) -> [String: Set<String>] {
        guard !modules.isEmpty, let layout = ProjectLayout.discover(paths: [root]) else { return [:] }
        let classification = ProjectClassification.load(layout)
        var byPath: [String: Set<String>?] = [:]
        var covering: [String: Set<String>] = [:]
        for mutation in mutations {
            if byPath[mutation.path] == nil {
                let targets = classification.testTargets(covering: SourcePath.canonical(root + "/" + mutation.path))
                // SwiftPM spells a module with `_` for spaces and dashes; Xcode's result bundles keep the target name.
                let names = Set(targets.flatMap { [moduleName($0.name), $0.name] }).intersection(modules)
                byPath[mutation.path] = .some(names.isEmpty ? nil : names)
            }
            if let names = byPath[mutation.path] ?? nil { covering[mutation.id] = names }
        }
        return covering
    }

    /// SwiftPM's module name for a target: every character outside `[A-Za-z0-9_]` becomes `_`, and a leading digit
    /// gets one before it.
    static func moduleName(_ target: String) -> String {
        var name = String(target.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
        if let first = name.first, first.isNumber { name = "_" + name }
        return name
    }

    /// The test functions (not suites) declared in the Swift Testing event streams among `evidence`, identifiers
    /// without their source location, sorted.
    static func testFunctions(in evidence: [String], logs root: String) -> [String] {
        var tests: Set<String> = []
        for path in evidence where path.hasSuffix(".events.jsonl") {
            guard let bytes = try? BoundedFileReader.read(path: root + "/" + path, cap: 64 << 20) else { continue }
            for line in bytes.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                guard let document = try? AemiJSON.parse(Array(line)) else { continue }
                let root = document.root
                guard root.kind.string == "test", root.payload.kind.string == "function",
                    let id = root.payload.id.string
                else { continue }
                tests.insert(testName(id))
            }
        }
        return tests.sorted()
    }

    /// Removes `directory`, retrying while another process adds to it; true when it is gone.
    static func remove(_ directory: String) -> Bool {
        for attempt in 0..<5 {
            if (try? FileManager.default.removeItem(atPath: directory)) != nil
                || !FileManager.default.fileExists(atPath: directory)
            {
                return true
            }
            usleep(UInt32(100_000 << attempt))
        }
        return false
    }

    /// Writes one batch's schemas into the snapshot, keeping the originals to restore. In place, each original is made
    /// recoverable through `journal` before its file is rewritten.
    func install(_ group: [Mutation], in snapshot: WorkspaceSnapshot, journal: InPlaceJournal?, token: String) throws
        -> InstalledSchema
    {
        var originals: [String: Data] = [:]
        var rendered: [String: RenderedSchema] = [:]
        // One numbering for the whole batch: every file's switches share a run's control page.
        let slots = SharedControlLayout.slots(for: group)
        do {
            for (relative, sites) in Dictionary(grouping: group, by: \.path).sorted(by: { $0.key < $1.key }) {
                let path = try snapshot.path(for: relative)
                let bytes = try BoundedFileReader.read(path: path, cap: 2 << 20)
                guard let source = String(bytes: bytes, encoding: .utf8) else { throw LitmusFailure("not UTF-8") }
                let schema = try SchemaWriter.schema(source, mutations: sites, token: token, slots: slots)
                originals[path] = Data(bytes)
                if let journal {
                    try journal.rewrite(path, original: bytes, schema: Array(schema.text.utf8))
                } else {
                    // Scratch files the next run re-creates: atomic, not synced.
                    try AtomicFile.replace(at: path, with: Array(schema.text.utf8), durability: .none)
                }
                rendered[path] = schema
            }
        } catch {
            try InstalledSchema(originals: originals, rendered: rendered, journal: journal).restore()
            throw error
        }
        return InstalledSchema(originals: originals, rendered: rendered, journal: journal)
    }
}
