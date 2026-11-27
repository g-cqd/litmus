internal import Foundation
internal import Synchronization

/// What `RunSession` tells a UI session harness: each batch's covered mutants and the test modules each runs.
protocol UISessionControl: AnyObject, Sendable {
    var statistics: UISessionStatistics { get }
    func register(_ sites: [(id: String, modules: Set<String>?)])
}

public struct UISessionStatistics: Sendable, Equatable {
    public var sessions = 0
    public var served = 0
    public var fallbacks = 0
}

/// Runs the first runs of a batch's UI-test mutants in one `xcodebuild test-without-building`: one test-plan
/// configuration per mutant, each launching the app with its own activation variables. Only first runs are shared:
/// kills, crashes and timeouts are rerun fresh and alone by the judge, so a session can decide survivors, never kills.
final class UISessionHarness<Executor: ProcessExecutor>: TestHarness, UISessionControl {
    struct Served: Sendable {
        let result: TestRunResult
        let directory: String
    }

    struct State {
        var modules: [String: Set<String>?] = [:]
        var served: [String: Served] = [:]
        var statistics = UISessionStatistics()
    }

    let inner: XcodeHarness<Executor>
    let state = Mutex(State())

    init(inner: XcodeHarness<Executor>) { self.inner = inner }

    var kind: String { inner.kind }
    var capabilities: HarnessCapabilities { inner.capabilities }
    var statistics: UISessionStatistics { state.withLock { $0.statistics } }

    /// Whether the built `.xctestrun` has a UI test bundle; a session only helps where the app launches per test.
    static func hasUITests(products: String) throws -> Bool {
        let runs = try FileManager.default.contentsOfDirectory(atPath: products).filter { $0.hasSuffix(".xctestrun") }
        guard runs.count == 1, let run = runs.first else { return false }
        return try XCTestRunTarget.targets(xctestrun: products + "/" + run, products: products, platforms: "")
            .contains(where: \.isUITest)
    }

    /// A new batch: its schema replaces the last one, so nothing decided before is served again.
    func register(_ sites: [(id: String, modules: Set<String>?)]) {
        state.withLock { state in
            for served in state.served.values { try? FileManager.default.removeItem(atPath: served.directory) }
            state.served = [:]
            state.modules = Dictionary(sites.map { ($0.id, $0.modules) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func run(_ request: TestRunRequest) async throws -> TestRunResult {
        guard !request.alone, !request.activeID.isEmpty, request.onlySwiftTesting == nil else {
            return try await inner.run(request)
        }
        if let served = take(request.activeID) { return serve(served, request) }
        let group: [String] = state.withLock { state in
            guard let modules = state.modules[request.activeID], modules == request.onlyModules else { return [] }
            let peers = state.modules.filter { $0.key != request.activeID && $0.value == modules }.keys.sorted()
            return [request.activeID] + peers
        }
        if group.count > 1 {
            try await session(group, like: request)
            if let served = take(request.activeID) { return serve(served, request) }
        }
        return try await inner.run(request)
    }

    private func take(_ id: String) -> Served? {
        state.withLock { $0.served.removeValue(forKey: id) }
    }

    /// The session's result for one mutant, its activation markers copied where the judge reads them.
    private func serve(_ served: Served, _ request: TestRunRequest) -> TestRunResult {
        let fm = FileManager.default
        let coverage = served.directory + "/coverage"
        for marker in (try? fm.contentsOfDirectory(atPath: coverage)) ?? [] {
            fm.createFile(atPath: request.coverageDirectory + "/" + marker, contents: nil)
        }
        try? fm.removeItem(atPath: served.directory)
        state.withLock { $0.statistics.served += 1 }
        return served.result
    }
}
