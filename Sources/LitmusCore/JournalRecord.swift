internal import AemiProtobuf

/// A verdict as the journal stores it: a native protobuf message, with field numbers that never change (upstream AP-2:
/// AemiProtobuf's `@ProtoMessage` covers these shapes). Version-1 journals stored the AemiJSON of `MutationResult`.
@ProtoMessage(unknownFields: .discard)
struct JournalRecord: Equatable {
    @ProtoField(1) var mutation: JournalMutation? = nil
    @ProtoField(2) var verdict: String = ""
    @ProtoField(3) var counts: JournalCounts? = nil
    @ProtoField(4) var reason: String = ""
    @ProtoField(5) var evidence: [String] = []
    @ProtoField(6) var nanoseconds: Int64 = 0
}

@ProtoMessage(unknownFields: .discard)
struct JournalMutation: Equatable {
    @ProtoField(1) var id: String = ""
    @ProtoField(2) var path: String = ""
    @ProtoField(3) var line: Int64 = 0
    @ProtoField(4) var column: Int64 = 0
    @ProtoField(5) var operatorID: String = ""
    @ProtoField(6) var start: Int64 = 0
    @ProtoField(7) var end: Int64 = 0
    @ProtoField(8) var original: String = ""
    @ProtoField(9) var replacement: String = ""
    @ProtoField(10) var sourceFingerprint: String = ""
    @ProtoField(11) var declaration: String? = nil
    @ProtoField(12) var declarationDigest: String? = nil
}

@ProtoMessage(unknownFields: .discard)
struct JournalCounts: Equatable {
    @ProtoField(1) var passed: Int64 = 0
    @ProtoField(2) var failed: Int64 = 0
    @ProtoField(3) var skipped: Int64 = 0
}

extension JournalRecord {
    init(_ result: MutationResult) {
        let mutation = result.mutation
        self.init()
        self.mutation = JournalMutation(
            id: mutation.id,
            path: mutation.path,
            line: Int64(mutation.line),
            column: Int64(mutation.column),
            operatorID: mutation.operatorID.rawValue,
            start: Int64(mutation.start),
            end: Int64(mutation.end),
            original: mutation.original,
            replacement: mutation.replacement,
            sourceFingerprint: mutation.sourceFingerprint,
            declaration: mutation.declaration,
            declarationDigest: mutation.declarationDigest
        )
        verdict = result.verdict.rawValue
        counts = result.tests.map {
            JournalCounts(passed: Int64($0.passed), failed: Int64($0.failed), skipped: Int64($0.skipped))
        }
        reason = result.reason
        evidence = result.evidence
        nanoseconds = result.nanoseconds
    }

    /// The result, or nil when a field holds a value this version does not know (a verdict or operator added later).
    var result: MutationResult? {
        guard let stored = mutation, let operatorID = MutationOperator(rawValue: stored.operatorID),
            let verdict = Verdict(rawValue: verdict)
        else { return nil }
        let mutation = Mutation(
            id: stored.id,
            path: stored.path,
            line: Int(stored.line),
            column: Int(stored.column),
            operatorID: operatorID,
            start: Int(stored.start),
            end: Int(stored.end),
            original: stored.original,
            replacement: stored.replacement,
            sourceFingerprint: stored.sourceFingerprint,
            declaration: stored.declaration,
            declarationDigest: stored.declarationDigest
        )
        return MutationResult(
            mutation: mutation,
            verdict: verdict,
            tests: counts.map { TestCounts(passed: Int($0.passed), failed: Int($0.failed), skipped: Int($0.skipped)) },
            reason: reason,
            evidence: evidence,
            nanoseconds: nanoseconds
        )
    }
}
