internal import Foundation
internal import SourceCorpus

extension UISessionHarness {
    /// One `xcodebuild` for every mutant of `group`, which all run `request`'s test modules. A configuration that is
    /// missing from the results or ran another test population is left unserved: its mutant runs fresh.
    func session(_ group: [String], like request: TestRunRequest) async throws {
        let index = state.withLock { state in
            state.statistics.sessions += 1
            for id in group { state.modules.removeValue(forKey: id) }
            return state.statistics.sessions
        }
        let name = "ui-session-\(index)"
        let root = inner.artifacts + "/ui-sessions/\(name)"
        let products = inner.artifacts + "/DerivedData/Build/Products"
        var configurations: [(name: String, targets: [[String: Any]])] = []
        for id in group {
            let member = try Self.member(of: request, activating: id, in: root + "/\(id)")
            guard
                let targets = XcodeConfigurations.testTargets(
                    try inner.testRunPlist(request: member, products: products)
                )
            else { return }
            configurations.append(("litmus-\(id)", targets))
        }
        let xctestrun = "\(inner.logs)/\(name).xctestrun"
        let data = try PropertyListSerialization.data(
            fromPropertyList: XcodeConfigurations.plist(configurations),
            format: .xml,
            options: 0
        )
        try data.write(to: URL(fileURLWithPath: xctestrun), options: .atomic)
        let bundle = "\(inner.logs)/\(name).xcresult"
        defer { try? FileManager.default.removeItem(atPath: bundle) }
        let start = ContinuousClock.now
        let output = try await inner.executor.execute(
            try inner.driver.testCommand(
                workspace: inner.workspace,
                artifacts: inner.artifacts,
                result: bundle,
                xctestrun: xctestrun,
                onlyTesting: request.onlyModules.map { Array($0) },
                skipTesting: Array(request.skipModules)
            ),
            directory: inner.driver.executionDirectory(workspace: inner.workspace),
            environment: subjectEnvironment(nil),
            timeout: request.deadline * group.count,
            supervision: request.supervision
        )
        try writeLog(output, path: "\(inner.logs)/\(name).log")
        guard !output.timedOut, output.stopReason == nil else { return }
        let tests = try await inner.executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["xcresulttool", "get", "test-results", "tests", "--path", bundle, "--compact"]
            ),
            directory: inner.driver.executionDirectory(workspace: inner.workspace),
            environment: subjectEnvironment(nil),
            timeout: 60
        )
        guard tests.exitStatus == 0, !tests.truncated, let results = XcodeConfigurations.counts(tests.stdout) else {
            return
        }
        let share = nanoseconds(since: start) / Int64(group.count)
        let population = results.values.map { $0.values.reduce(0) { $0 + $1.total } }.max() ?? 0
        state.withLock { state in
            for id in group {
                guard let modules = results["litmus-\(id)"] else { continue }
                let counts = modules.values.reduce(TestCounts(passed: 0, failed: 0, skipped: 0)) {
                    TestCounts(
                        passed: $0.passed + $1.passed,
                        failed: $0.failed + $1.failed,
                        skipped: $0.skipped + $1.skipped
                    )
                }
                guard counts.total == population, population > 0 else { continue }
                let failed = counts.failed > 0
                var result = TestRunResult(
                    outcome: failed ? .failed : .passed,
                    counts: counts,
                    nanoseconds: share,
                    evidence: ["logs/\(name).log"],
                    reason: failed ? "a test failed (shared UI session)" : "every test passed (shared UI session)"
                )
                result.moduleCounts = modules
                result.ranInSharedWorker = true
                if failed { result.failedModule = modules.filter { $0.value.failed > 0 }.keys.sorted().first }
                state.served[id] = Served(result: result, directory: root + "/\(id)")
            }
            state.statistics.fallbacks += group.filter { state.served[$0] == nil }.count
        }
    }

    /// `request` for mutant `id`, with its own marker and temporary directories under `directory`.
    static func member(of request: TestRunRequest, activating id: String, in directory: String) throws
        -> TestRunRequest
    {
        let coverage = directory + "/coverage", temporary = directory + "/tmp"
        for path in [coverage, temporary] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        var member = TestRunRequest(
            name: request.name,
            activeID: id,
            coverageDirectory: coverage,
            temporaryDirectory: temporary,
            deadline: request.deadline,
            failFast: false
        )
        member.onlyModules = request.onlyModules
        member.skipModules = request.skipModules
        member.environmentToken = request.environmentToken
        member.supervision = request.supervision
        return member
    }
}
