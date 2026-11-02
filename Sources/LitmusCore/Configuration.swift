internal import AemiJSON
internal import AnalyzerConfiguration
internal import Foundation

/// Only syntax planning settings; execution inputs must remain explicit in argv/provenance.
public struct LitmusConfiguration: Decodable, Sendable {
    public var exclude: [String] = []

    /// Resolves the family's shared top-level exclusions plus `.litmus.json`; rejects duplicate/unknown keys.
    /// A `litmus` section of `.swift-analyzers.json` is read as well (analyzerkit ADR-0030), with the shared keys only.
    public static func load(root: String, explicit: String?) throws -> Self {
        let resolved = try SharedConfiguration.resolve(
            for: SharedConfiguration.Tool(name: "litmus", fileName: ".litmus.json", keys: []),
            explicit: explicit,
            currentDirectory: root,
            analyzedPaths: [root]
        )
        // Known shared keys are validated by analyzerkit. This first execution policy does not interpret build defines.
        let value = try ArtifactCodec.decode(SharedValues.self, bytes: resolved.json)
        guard value.defines?.isEmpty ?? true, value.platforms?.isEmpty ?? true,
            value.includeRegions?.isEmpty ?? true, value.excludeRegions?.isEmpty ?? true
        else {
            throw LitmusFailure(
                "this version accepts exclude only; use the actual scheme/destination for build conditions and fixed production-region policy"
            )
        }
        return Self(exclude: value.exclude ?? [])
    }
    private struct SharedValues: Decodable {
        let exclude: [String]?
        let defines: [String]?
        let platforms: [String]?
        let includeRegions: [String]?
        let excludeRegions: [String]?
    }
}
