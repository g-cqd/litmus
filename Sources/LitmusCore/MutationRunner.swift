internal import Foundation
internal import SourceCorpus

/// Conservative serial executor. Source batches amortize builds; process-per-mutant isolation prevents shared-test state.
public struct MutationRunner<Executor: ProcessExecutor>: Sendable {
    private let executor: Executor
    public init(executor: Executor) { self.executor = executor }

    /// Creates an owned snapshot, validates unmutated and inactive-schema baselines, then executes every site.
    /// Failed mutants require a passing inactive control and a second failing active execution.
    /// - Important: Only run on trusted project code; copying is not a security sandbox.
    /// - Throws: On baseline failure, cancellation or artifact/I/O failure; writes an incomplete checkpoint when possible.
    public func run(
        driver: BuildDriver,
        outputDirectory: String,
        exclude: [String] = [],
        batchSize: Int = 64,
        buildTimeout: Int = 900,
        testTimeout: Int = 120,
        keepWorkspace: Bool = false
    ) async throws -> RunArtifact {
        guard (1...256).contains(batchSize), (1...86_400).contains(buildTimeout), (1...86_400).contains(testTimeout)
        else {
            throw LitmusFailure("batch size/timeouts outside documented bounds")
        }
        let fm = FileManager.default
        let output = SourcePath.canonical(outputDirectory), root = SourcePath.canonical(driver.root)
        guard output != root, !output.hasPrefix(root + "/"), !fm.fileExists(atPath: output) else {
            throw LitmusFailure("run directory must be new and outside original source root")
        }
        try fm.createDirectory(atPath: output, withIntermediateDirectories: true)
        let snapshot = try WorkspaceSnapshot.create(source: root, destination: output + "/workspace")
        let clonePlan = try await MutationPlanner.plan(root: snapshot.root, exclude: exclude)
        let plan = MutationPlan(
            root: root,
            analyzedFiles: clonePlan.analyzedFiles,
            mutations: clonePlan.mutations,
            suppressed: clonePlan.suppressed,
            notes: clonePlan.notes
        )
        guard !plan.mutations.isEmpty else {
            throw LitmusFailure("no mutable production sites; inspect plan exclusions")
        }
        guard Set(plan.mutations.map(\.id)).count == plan.mutations.count else {
            throw LitmusFailure("mutation ID collision")
        }
        let environment = buildEnvironment()
        let toolchain = try await executor.execute(
            ToolCommand(
                executable: "/usr/bin/xcrun",
                arguments: [driver.usesXcode ? "xcodebuild" : "swift", "-version"]
            ),
            directory: snapshot.root,
            environment: environment,
            timeout: 30
        )
        guard toolchain.exitStatus == 0 else { throw LitmusFailure("toolchain identification failed") }
        let provenance = RunProvenance(
            toolVersion: "0.1.0-dev",
            snapshotSHA256: snapshot.digest,
            inputs: snapshot.entries,
            driver: driver,
            toolchain: String(decoding: toolchain.stdout, as: UTF8.self),
            startedAt: ISO8601DateFormatter().string(from: Date()),
            executionPolicy: "full-suite/process-per-mutant/confirmed-failure/v1"
        )
        var artifact = RunArtifact(provenance: provenance, plan: plan)
        let resultPath = output + "/run.json"
        try checkpoint(artifact, at: resultPath)
        let artifacts = output + "/artifacts"
        try fm.createDirectory(atPath: artifacts, withIntermediateDirectories: true)
        do {
            let baselineBuild = try await build(
                driver,
                workspace: snapshot.root,
                artifacts: artifacts,
                output: output,
                name: "baseline-build",
                timeout: buildTimeout
            )
            guard baselineBuild else { throw LitmusFailure("unmutated build failed; no mutant verdicts are valid") }
            let baseline = try await test(
                driver,
                workspace: snapshot.root,
                artifacts: artifacts,
                output: output,
                name: "baseline-test",
                activeID: "",
                timeout: testTimeout
            )
            guard baseline.verdict == .survived, let baselineCounts = baseline.tests else {
                throw LitmusFailure("unmutated baseline did not pass with executed tests")
            }
            let grouped = SchemaWriter.batches(plan.mutations, limit: batchSize)
            for (batchIndex, batch) in grouped.enumerated() {
                try Task.checkCancellation()
                let byFile = Dictionary(grouping: batch, by: \.path)
                var originals: [String: Data] = [:]
                for relative in byFile.keys.sorted() {
                    let path = try snapshot.path(for: relative)
                    let bytes = try BoundedFileReader.read(path: path, cap: 2 << 20)
                    originals[path] = Data(bytes)
                    guard let source = String(bytes: bytes, encoding: .utf8), let mutations = byFile[relative] else {
                        throw LitmusFailure("invalid source/group")
                    }
                    let rewritten = try SchemaWriter.render(source, mutations: mutations)
                    try Data(rewritten.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                let prefix = "schema-\(batchIndex)"
                let built = try await build(
                    driver,
                    workspace: snapshot.root,
                    artifacts: artifacts,
                    output: output,
                    name: prefix + "-build",
                    timeout: buildTimeout
                )
                if built {
                    let inactive = try await test(
                        driver,
                        workspace: snapshot.root,
                        artifacts: artifacts,
                        output: output,
                        name: prefix + "-control",
                        activeID: "",
                        timeout: testTimeout
                    )
                    if inactive.verdict == .survived && inactive.tests == baselineCounts {
                        for site in batch {
                            try Task.checkCancellation()
                            let name = "mutant-" + site.id
                            var observed = try await test(
                                driver,
                                workspace: snapshot.root,
                                artifacts: artifacts,
                                output: output,
                                name: name,
                                activeID: site.id,
                                timeout: testTimeout
                            )
                            if let counts = observed.tests,
                                counts.passed + counts.failed + counts.skipped != baselineCounts.passed
                                    + baselineCounts.skipped
                            {
                                observed = Observation(
                                    verdict: .infrastructureError,
                                    tests: counts,
                                    reason: "executed test population differs from baseline",
                                    evidence: observed.evidence
                                )
                            }
                            if observed.verdict == .killed {
                                let control = try await test(
                                    driver,
                                    workspace: snapshot.root,
                                    artifacts: artifacts,
                                    output: output,
                                    name: name + "-control",
                                    activeID: "",
                                    timeout: testTimeout
                                )
                                let repeatActive = try await test(
                                    driver,
                                    workspace: snapshot.root,
                                    artifacts: artifacts,
                                    output: output,
                                    name: name + "-confirm",
                                    activeID: site.id,
                                    timeout: testTimeout
                                )
                                if control.verdict != .survived || control.tests != baselineCounts
                                    || repeatActive.verdict != .killed || repeatActive.tests != observed.tests
                                {
                                    observed = Observation(
                                        verdict: .infrastructureError,
                                        tests: observed.tests,
                                        reason: "kill not reproducible or inactive control failed",
                                        evidence: observed.evidence + control.evidence + repeatActive.evidence
                                    )
                                } else {
                                    observed = Observation(
                                        verdict: .killed,
                                        tests: observed.tests,
                                        reason: "two failing active runs with a passing inactive control",
                                        evidence: observed.evidence + control.evidence + repeatActive.evidence
                                    )
                                }
                            }
                            replace(site, observation: observed, in: &artifact)
                            try checkpoint(artifact, at: resultPath)
                        }
                    } else {
                        for site in batch {
                            replace(
                                site,
                                observation: Observation(
                                    verdict: .infrastructureError,
                                    tests: inactive.tests,
                                    reason: "inactive schema baseline differs from unmutated baseline",
                                    evidence: inactive.evidence
                                ),
                                in: &artifact
                            )
                        }
                    }
                } else {
                    // A compiler failure is not sufficient evidence of an invalid individual mutant.
                    for site in batch {
                        replace(
                            site,
                            observation: Observation(
                                verdict: .infrastructureError,
                                tests: nil,
                                reason: "schema build failed; individual validity unresolved",
                                evidence: [prefix + "-build.log"]
                            ),
                            in: &artifact
                        )
                    }
                }
                for (path, data) in originals { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
                try checkpoint(artifact, at: resultPath)
            }
            artifact.complete = true
            try checkpoint(artifact, at: resultPath)
            try ArtifactCodec.write(artifact, path: output + "/run.pb")
            if !keepWorkspace { try fm.removeItem(atPath: snapshot.root) }
            return artifact
        } catch {
            artifact.notes.append("run stopped: \(error); partial evidence is not a successful run")
            do { try checkpoint(artifact, at: resultPath) } catch let writeError {
                throw LitmusFailure("execution failed: \(error); checkpoint failed: \(writeError)")
            }
            // Failed snapshots are retained for diagnosis; the source checkout was never written by Litmus.
            throw error
        }
    }

    private func replace(_ site: Mutation, observation: Observation, in artifact: inout RunArtifact) {
        if let index = artifact.results.firstIndex(where: { $0.mutation.id == site.id }) {
            artifact.results[index] = MutationResult(
                mutation: site,
                verdict: observation.verdict,
                tests: observation.tests,
                reason: observation.reason,
                evidence: observation.evidence
            )
        }
    }
    private func checkpoint(_ artifact: RunArtifact, at path: String) throws {
        try ArtifactCodec.write(artifact, path: path)
    }
    private func buildEnvironment() -> [String: String] {
        var env = ["LITMUS_ACTIVE_ID": ""]
        // analyzerkit intentionally strips this; explicitly preserve the user's selected Xcode for this trusted build.
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { env["DEVELOPER_DIR"] = developer }
        return env
    }
    private func build(
        _ driver: BuildDriver,
        workspace: String,
        artifacts: String,
        output: String,
        name: String,
        timeout: Int
    ) async throws -> Bool {
        let result = try await executor.execute(
            driver.buildCommand(workspace: workspace, artifacts: artifacts),
            directory: workspace,
            environment: buildEnvironment(),
            timeout: timeout
        )
        try log(result, path: output + "/" + name + ".log")
        return result.exitStatus == 0 && !result.timedOut
    }
    private func test(
        _ driver: BuildDriver,
        workspace: String,
        artifacts: String,
        output: String,
        name: String,
        activeID: String,
        timeout: Int
    ) async throws -> Observation {
        var env = buildEnvironment(); env["LITMUS_ACTIVE_ID"] = activeID
        let resultPath = output + "/" + name + (driver.usesXcode ? ".xcresult" : ".xml")
        let xctestrun =
            driver.usesXcode
            ? try preparedTestRun(artifacts: artifacts, output: output + "/" + name + ".xctestrun", activeID: activeID)
            : nil
        let command = try driver.testCommand(
            workspace: workspace,
            artifacts: artifacts,
            result: resultPath,
            xctestrun: xctestrun
        )
        let process = try await executor.execute(command, directory: workspace, environment: env, timeout: timeout)
        let logPath = output + "/" + name + ".log"
        try log(process, path: logPath)
        if process.timedOut {
            return Observation(
                verdict: .timeout,
                tests: nil,
                reason: "test deadline exceeded; not counted as a kill",
                evidence: [name + ".log"]
            )
        }
        do {
            let counts: TestCounts
            var evidence = [name + ".log"]
            if driver.usesXcode {
                let summary = try await executor.execute(
                    ToolCommand(
                        executable: "/usr/bin/xcrun",
                        arguments: [
                            "xcresulttool", "get", "test-results", "summary", "--path", resultPath, "--compact",
                        ]
                    ),
                    directory: workspace,
                    environment: buildEnvironment(),
                    timeout: 30
                )
                guard summary.exitStatus == 0, !summary.truncated else {
                    throw LitmusFailure("xcresult summary unavailable")
                }
                try Data(summary.stdout).write(
                    to: URL(fileURLWithPath: output + "/" + name + ".summary.json"),
                    options: .atomic
                )
                counts = try TestEvidence.xcresult(summary.stdout)
                evidence += [name + ".summary.json", URL(fileURLWithPath: resultPath).lastPathComponent]
            } else {
                let reports = try TestEvidence.swiftPM(at: resultPath)
                counts = reports.counts
                evidence += reports.paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            }
            let verdict = Verdict.classify(exitStatus: process.exitStatus, tests: counts)
            return Observation(
                verdict: verdict,
                tests: counts,
                reason: "structured test results and process status",
                evidence: evidence
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Observation(
                verdict: .infrastructureError,
                tests: nil,
                reason: "test evidence rejected: \(error)",
                evidence: [name + ".log"]
            )
        }
    }
    private func log(_ result: ProcessOutput, path: String) throws {
        let header =
            "exit=\(result.exitStatus) timeout=\(result.timedOut) truncated=\(result.truncated)\n--- stdout ---\n"
        let bytes = Array(header.utf8) + result.stdout + Array("\n--- stderr ---\n".utf8) + result.stderr
        try Data(bytes).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private struct Observation {
        let verdict: Verdict
        let tests: TestCounts?
        let reason: String
        let evidence: [String]
    }

    /// PropertyListSerialization supplies heterogeneous SDK data; the untyped boundary is contained here.
    /// Xcode-relative paths are absolutized before moving the plist outside Build/Products.
    private func preparedTestRun(artifacts: String, output: String, activeID: String) throws -> String {
        let fm = FileManager.default
        let products = artifacts + "/DerivedData/Build/Products"
        let candidates = try fm.contentsOfDirectory(atPath: products).filter { $0.hasSuffix(".xctestrun") }.sorted()
        guard candidates.count == 1, let file = candidates.first else {
            throw LitmusFailure("expected exactly one .xctestrun artifact; found \(candidates.count)")
        }
        let bytes = try BoundedFileReader.read(path: products + "/" + file, cap: 4 << 20)
        // SAFETY: the API is marked unsafe for its optional output pointer. We pass nil;
        // the input is owned bounded Data, and no caller-provided pointer is dereferenced or retained.
        let plist = try unsafe PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
        var patchedTargets = 0
        func patch(_ value: Any, depth: Int = 0) throws -> Any {
            guard depth <= 64 else { throw LitmusFailure("xctestrun nesting exceeds 64") }
            if let dictionary = value as? [String: Any] {
                var updated = try dictionary.mapValues { try patch($0, depth: depth + 1) }
                if dictionary["TestBundlePath"] != nil {
                    for key in ["EnvironmentVariables", "TestingEnvironmentVariables"] {
                        var env = updated[key] as? [String: String] ?? [:]
                        env["LITMUS_ACTIVE_ID"] = activeID
                        updated[key] = env
                    }
                    patchedTargets += 1
                }
                return updated
            }
            if let array = value as? [Any] { return try array.map { try patch($0, depth: depth + 1) } }
            if let string = value as? String { return string.replacingOccurrences(of: "__TESTROOT__", with: products) }
            return value
        }
        let patched = try patch(plist)
        guard patchedTargets > 0 else { throw LitmusFailure("no supported test target in .xctestrun") }
        let data = try PropertyListSerialization.data(fromPropertyList: patched, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        return output
    }
}
