internal import Foundation
internal import IndexStoreSupport
internal import ProjectModel
internal import SourceCorpus
internal import Synchronization

#if canImport(IndexStoreDB)
    internal import IndexStoreDB
#endif

/// Compiler-resolved symbol queries over an existing index store (`--index-store-path` or auto-discovered from `.build`
/// / `DerivedData`), keyed by relative file path so workspace copies resolve against the subject's store.
///
/// When no store exists, `libIndexStore` is unavailable, or a file has been modified since the store was written,
/// queries return `false` and the planner falls back to conservative syntactic type checks.
public final class TypeOracle: Sendable {
    public struct Location: Hashable, Sendable {
        public let line: Int
        public let column: Int
        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    /// Canonical root against which indexed unit paths were recorded.
    public let indexedRoot: String
    /// Canonical store directory when opened, nil when unavailable.
    public let storePath: String?
    /// Human-readable status note when an explicit path was rejected or auto-discovery opened a store.
    public let diagnostic: String?

    #if canImport(IndexStoreDB)
        private let session: IndexStoreSession?
        private let queries: IndexQueries?
    #endif
    private let cache = Mutex<[String: [Location: [String]]]>([:])

    private init(indexedRoot: String, storePath: String?, diagnostic: String?) {
        self.indexedRoot = indexedRoot
        self.storePath = storePath
        self.diagnostic = diagnostic
        #if canImport(IndexStoreDB)
            self.session = nil
            self.queries = nil
        #endif
    }

    #if canImport(IndexStoreDB)
        private init(
            indexedRoot: String,
            storePath: String,
            diagnostic: String?,
            session: IndexStoreSession
        ) {
            self.indexedRoot = indexedRoot
            self.storePath = storePath
            self.diagnostic = diagnostic
            self.session = session
            self.queries = IndexQueries(session: session)
        }
    #endif

    public static func empty(root: String = "") -> TypeOracle {
        TypeOracle(indexedRoot: root, storePath: nil, diagnostic: nil)
    }

    /// Opens an index store for `analyzedRelativePaths` under `indexedRoot`.
    /// - Throws: `LitmusFailure` only when `explicitStorePath` is non-nil and invalid/unreadable.
    public static func open(
        indexedRoot: String,
        analyzedRelativePaths: [String],
        explicitStorePath: String? = nil
    ) async throws -> TypeOracle {
        let canonicalRoot = SourcePath.canonical(indexedRoot)
        #if canImport(IndexStoreDB)
            let candidateStore: String?
            if let explicit = explicitStorePath, !explicit.isEmpty {
                switch IndexStoreLocation.resolve(explicit) {
                case .store(let resolved):
                    candidateStore = resolved
                case .notAStore(_, let reason):
                    throw LitmusFailure("--index-store-path: \(reason)")
                }
            } else if let layout = ProjectLayout.discover(paths: [canonicalRoot]) {
                let derivedData = [
                    NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
                ]
                candidateStore = IndexStoreLocation.discover(layout: layout, derivedDataRoots: derivedData)
            } else {
                candidateStore = nil
            }
            guard let store = candidateStore else {
                return TypeOracle(indexedRoot: canonicalRoot, storePath: nil, diagnostic: nil)
            }
            let toolchain = await ToolchainResolution.resolve()
            guard let library = toolchain.libraryPath else {
                if explicitStorePath != nil {
                    throw LitmusFailure("--index-store-path: no trusted libIndexStore.dylib found")
                }
                return TypeOracle(indexedRoot: canonicalRoot, storePath: nil, diagnostic: nil)
            }
            let cacheRoot =
                FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                .map { $0.path + "/litmus" }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("litmus-index").path
            let fullPaths = analyzedRelativePaths.map { canonicalRoot + "/" + $0 }
            switch IndexStoreSession.open(store, cacheRoot: cacheRoot, library: library, analyzedFiles: fullPaths) {
            case .usable(let session):
                return TypeOracle(
                    indexedRoot: canonicalRoot,
                    storePath: session.store,
                    diagnostic: "TypeOracle: opened index store at \(session.store)",
                    session: session
                )
            case .notUsable(let path, _):
                return TypeOracle(
                    indexedRoot: canonicalRoot,
                    storePath: nil,
                    diagnostic: "TypeOracle: index store at \(path) covers no analyzed file"
                )
            case .notAStore(let reason):
                if explicitStorePath != nil { throw LitmusFailure("--index-store-path: \(reason)") }
                return TypeOracle(indexedRoot: canonicalRoot, storePath: nil, diagnostic: nil)
            case .failed(let reason):
                if explicitStorePath != nil { throw LitmusFailure("--index-store-path: \(reason)") }
                return TypeOracle(indexedRoot: canonicalRoot, storePath: nil, diagnostic: reason)
            }
        #else
            if explicitStorePath != nil {
                throw LitmusFailure("--index-store-path: IndexStoreDB is not available on this platform")
            }
            return TypeOracle(indexedRoot: canonicalRoot, storePath: nil, diagnostic: nil)
        #endif
    }

    /// USRs recorded at 1-based `(line, column)` (UTF-8 column) in `relativePath` when the file's index unit is fresh.
    public func usrs(relativePath: String, line: Int, column: Int) -> [String] {
        let table = fileOccurrences(relativePath: relativePath)
        return table[Location(line: line, column: column)] ?? []
    }

    public enum FilterReturnShape: Sendable, Equatable {
        /// Returns `[Element]` (`Sequence.filter`, `_ArrayProtocol.filter` on `Array` / `ArraySlice` / `ContiguousArray`).
        case array
        /// Returns `Self` (`Set.filter`, `Dictionary.filter`, `RangeReplaceableCollection.filter` / `String.filter`).
        case sameReceiver
    }

    /// Classifies `.filter` at `(line, column)` by its compiler-resolved return type so the replacement matches `Self` vs `[Element]`.
    public func filterReturnShape(relativePath: String, line: Int, column: Int) -> FilterReturnShape? {
        for usr in usrs(relativePath: relativePath, line: line, column: column) {
            if usr.contains("6filterySay") || usr.hasPrefix("s:Sa6filter") {
                return .array
            }
            if usr.hasPrefix("s:Sh6filter") || usr.hasPrefix("s:SD6filter") || usr.hasPrefix("s:SmsE6filter")
                || usr.hasPrefix("s:SS6filter")
            {
                return .sameReceiver
            }
        }
        return nil
    }

    /// True when `.sorted` at `(line, column)` is `Sequence.sorted` returning `[Element]`, so `Swift.Array(base)` has
    /// the identical result type.
    public func isArrayReturningSorted(relativePath: String, line: Int, column: Int) -> Bool {
        usrs(relativePath: relativePath, line: line, column: column).contains { usr in
            usr.hasPrefix("s:ST") && usr.contains("6sortedSay")
        }
    }

    /// True when `.last` at `(line, column)` resolves to `BidirectionalCollection.last` (`Element?`), which guarantees
    /// `.first` exists on the same receiver with the identical type `Element?`.
    public func isBidirectionalLast(relativePath: String, line: Int, column: Int) -> Bool {
        usrs(relativePath: relativePath, line: line, column: column).contains { usr in
            usr.hasPrefix("s:SKsE4last")
        }
    }

    private func fileOccurrences(relativePath: String) -> [Location: [String]] {
        if let cached = cache.withLock({ $0[relativePath] }) { return cached }
        var loaded: [Location: [String]] = [:]
        #if canImport(IndexStoreDB)
            if let session, let queries {
                let fullPath = indexedRoot + "/" + relativePath
                if session.freshness.isCurrent(fullPath) {
                    for occ in queries.occurrences(inFile: fullPath) {
                        loaded[Location(line: occ.line, column: occ.column), default: []].append(occ.usr)
                    }
                }
            }
        #endif
        cache.withLock { $0[relativePath] = loaded }
        return loaded
    }
}
