internal import Foundation

/// One shard of a run (`--shard k/n`): the mutants of whole modules, so each shard rebuilds only what it
/// mutates, and `litmus merge` puts the shards back together.
public struct ShardSelection: Sendable, Equatable {
    /// 1-based.
    public let index: Int
    public let count: Int

    public init(index: Int, count: Int) throws {
        guard (1...1024).contains(count), (1...count).contains(index) else {
            throw LitmusFailure("--shard must be k/n with 1 ≤ k ≤ n ≤ 1024")
        }
        self.index = index
        self.count = count
    }

    /// `k/n`.
    public init(parsing text: String) throws {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let index = Int(parts[0]), let count = Int(parts[1]) else {
            throw LitmusFailure("--shard must be k/n, such as 2/4")
        }
        try self.init(index: index, count: count)
    }
}

/// What a shard ran, recorded so the shards can be checked and merged.
public struct ShardRecord: Codable, Sendable, Equatable {
    public let index: Int
    public let count: Int
    /// The module units this shard holds.
    public let units: [String]
    /// The whole plan: its mutant count and the SHA-256 of its sorted ids, the same in every shard.
    public let totalMutants: Int
    public let planDigest: String
}

enum Sharding {
    /// A mutant's module unit: the directory of its target (`Sources/<Target>`, `<Package>/Sources/<Target>`), or its
    /// file's directory when no `Sources`/`Tests` component names one.
    static func unit(of path: String) -> String {
        let parts = path.split(separator: "/")
        if let index = parts.firstIndex(where: { $0 == "Sources" || $0 == "Source" || $0 == "Tests" }),
            index + 1 < parts.count - 1
        {
            return parts[...(index + 1)].joined(separator: "/")
        }
        return parts.dropLast().joined(separator: "/")
    }

    /// The units of each shard: largest unit first, each to the shard with the fewest mutants (ties: lowest index).
    /// Deterministic for a given plan.
    static func partition(_ mutations: [Mutation], count: Int) -> [[String]] {
        let sizes = Dictionary(grouping: mutations, by: { unit(of: $0.path) }).mapValues(\.count)
        var shards = Array(repeating: (load: 0, units: [String]()), count: count)
        for (unit, size) in sizes.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }) {
            let target = shards.indices.min { (shards[$0].load, $0) < (shards[$1].load, $1) } ?? 0
            shards[target].load += size
            shards[target].units.append(unit)
        }
        return shards.map { $0.units.sorted() }
    }

    /// The plan limited to `shard`'s units, and its record.
    static func select(_ plan: MutationPlan, _ shard: ShardSelection) -> (MutationPlan, ShardRecord) {
        let units = partition(plan.mutations, count: shard.count)[shard.index - 1]
        let keep = Set(units)
        var selected = MutationPlan(
            root: plan.root,
            analyzedFiles: plan.analyzedFiles,
            mutations: plan.mutations.filter { keep.contains(unit(of: $0.path)) },
            suppressed: plan.suppressed.filter { keep.contains(unit(of: $0.path)) },
            notes: plan.notes
        )
        selected.scope = plan.scope.map { scope in
            let ids = Set(selected.mutations.map(\.id))
            return PlanScope(
                source: scope.source,
                digest: scope.digest,
                breadth: scope.breadth,
                changedFiles: scope.changedFiles,
                changedLines: scope.changedLines,
                swiftFiles: scope.swiftFiles,
                onChangedLines: scope.onChangedLines.filter(ids.contains)
            )
        }
        let record = ShardRecord(
            index: shard.index,
            count: shard.count,
            units: units,
            totalMutants: plan.mutations.count,
            planDigest: digest(plan.mutations)
        )
        return (selected, record)
    }

    static func digest(_ mutations: [Mutation]) -> String {
        Digest.sha256(Array(mutations.map(\.id).sorted().joined(separator: "\n").utf8))
    }

    /// The shards of one run as one artifact, after checking they are that: the same subject, toolchain, driver and
    /// policy; every index once; disjoint plans that together are the whole plan.
    static func merge(_ shards: [RunArtifact]) throws -> RunArtifact {
        guard let first = shards.first, let record = first.shard else {
            throw LitmusFailure("merge: give the run directories of every shard of one run")
        }
        for shard in shards {
            guard let other = shard.shard, other.count == record.count, other.totalMutants == record.totalMutants,
                other.planDigest == record.planDigest
            else { throw LitmusFailure("merge: the runs are not shards of the same plan") }
            let a = shard.provenance, b = first.provenance
            guard a.snapshotSHA256 == b.snapshotSHA256, a.toolVersion == b.toolVersion,
                a.executionPolicy == b.executionPolicy, a.toolchain == b.toolchain, a.driver == b.driver
            else {
                throw LitmusFailure(
                    "merge: shard \(other.index) ran on another subject, toolchain, driver or policy than shard \(record.index)"
                )
            }
        }
        let indices = shards.compactMap { $0.shard?.index }.sorted()
        guard indices == Array(1...record.count) else {
            throw LitmusFailure("merge: shards \(indices) given; every one of 1…\(record.count) is needed, once")
        }
        let mutations = shards.flatMap(\.plan.mutations)
        guard Set(mutations.map(\.id)).count == mutations.count, mutations.count == record.totalMutants,
            digest(mutations) == record.planDigest
        else { throw LitmusFailure("merge: the shards' plans overlap or do not make the whole plan") }
        let order = shards.sorted { ($0.shard?.index ?? 0) < ($1.shard?.index ?? 0) }
        var plan = MutationPlan(
            root: first.plan.root,
            analyzedFiles: first.plan.analyzedFiles,
            mutations: order.flatMap(\.plan.mutations),
            suppressed: order.flatMap(\.plan.suppressed),
            notes: first.plan.notes
        )
        plan.scope = first.plan.scope.map { scope in
            PlanScope(
                source: scope.source,
                digest: scope.digest,
                breadth: scope.breadth,
                changedFiles: scope.changedFiles,
                changedLines: scope.changedLines,
                swiftFiles: scope.swiftFiles,
                onChangedLines: order.flatMap { $0.plan.scope?.onChangedLines ?? [] }
            )
        }
        var merged = RunArtifact(provenance: first.provenance, plan: plan)
        merged.results = order.flatMap(\.results)
        merged.policy = first.policy
        merged.complete = order.allSatisfy(\.complete)
        merged.notes =
            ["merged from \(record.count) shards"]
            + order.flatMap { shard in shard.notes.map { "shard \(shard.shard?.index ?? 0): \($0)" } }
        for shard in order where shard.policy != first.policy {
            merged.notes.append("shard \(shard.shard?.index ?? 0) ran with another derived policy (workers, deadlines)")
        }
        for shard in order { merged.timings.merge(shard.timings) { $0 + $1 } }
        var cost = RunCost()
        for shard in order {
            guard let part = shard.cost else { continue }
            cost.wallSeconds = max(cost.wallSeconds, part.wallSeconds)
            cost.litmusCPUSeconds += part.litmusCPUSeconds
            cost.childCPUSeconds += part.childCPUSeconds
            cost.litmusPeakRSSMiB = max(cost.litmusPeakRSSMiB, part.litmusPeakRSSMiB)
            cost.childPeakRSSMiB = max(cost.childPeakRSSMiB, part.childPeakRSSMiB)
            cost.runDirectoryMiB += part.runDirectoryMiB
            cost.workspaceMiB += part.workspaceMiB
            cost.builds += part.builds
            cost.testRuns += part.testRuns
        }
        merged.cost = cost
        let budgets = order.compactMap(\.budget)
        if !budgets.isEmpty {
            var budget = BudgetRecord(seconds: budgets.first?.seconds, maxMutants: budgets.first?.maxMutants)
            budget.stoppedBy = budgets.compactMap(\.stoppedBy).first
            budget.untested = budgets.flatMap(\.untested)
            merged.budget = budget
        }
        return merged
    }
}

/// `litmus merge`: the shards' artifacts as one run, written to a new directory.
public enum ShardMerge {
    public static func merge(runDirectories: [String], output: String) throws -> RunArtifact {
        guard !FileManager.default.fileExists(atPath: output) else {
            throw LitmusFailure("merge: the output directory must be new")
        }
        let shards = try runDirectories.map { try ArtifactCodec.read(RunArtifact.self, path: $0 + "/run.json") }
        let merged = try Sharding.merge(shards)
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try ArtifactCodec.write(merged, path: output + "/run.json")
        try ArtifactCodec.write(merged, path: output + "/run.pb")
        return merged
    }
}
