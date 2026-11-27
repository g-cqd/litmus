internal import ReportSupport
internal import SwiftSyntax

struct SiteContext {
    let path: String
    let fingerprint: String
    let converter: SourceLocationConverter
    let anchors: Anchors
    let operators: Set<MutationOperator>
    let aridCalls: [String]
    let excludeDeclarations: [String]
    let oracle: TypeOracle
}

/// `text` with every run of whitespace replaced by one space, and none at either end: analyzerkit's anchored
/// normalisation, so mutant ids and acceptance anchors agree with the family's fingerprints.
func normalized(_ text: String) -> String { Fingerprint.normalized(text) }

/// A function-like declaration's name with its argument labels: `name(_:label:)`.
func signature(_ name: String, _ parameters: FunctionParameterListSyntax) -> String {
    name + "(" + parameters.map { ($0.firstName.text) + ":" }.joined() + ")"
}
